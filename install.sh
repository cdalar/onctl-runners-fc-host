#!/usr/bin/env bash
# One-shot bring-up for a new onctl-runner Firecracker host, using prebaked
# images pulled from Cloudflare R2 instead of building them locally
# (bootstrap-host.sh's default path, ~15-20 min) or copying them over SSH
# from an existing host (bootstrap-host.sh --source-host, needs that host
# reachable). This is the fast path once a build has already been published
# via publish-image.sh.
#
# The R2 bucket is private (docs/plans/fc-runner-image-pipeline.md's
# presigned-URL vs. standing-token discussion), so KERNEL_URL/ROOTFS_URL
# below must be short-lived presigned GET URLs, not the bucket path itself.
# Mint them right before running this, from wherever
# fc-host/scripts/.env.local's R2 credentials live:
#   bash fc-host/scripts/mint-image-links.sh
#
# Then, on the new host, as root. cdalar/onctl-runners is a PRIVATE repo, so
# an unauthenticated `curl .../install.sh` 404s (raw.githubusercontent.com
# doesn't serve private-repo content) -- copy the file over directly instead:
#   scp fc-host/scripts/install.sh <new-host>:/tmp/install.sh   # from a checkout that has repo access
#   ssh <new-host> "KERNEL_URL='...' ROOTFS_URL='...' bash /tmp/install.sh"
# (gcloud compute scp / gcloud compute ssh --command work the same way for a
# GCP host.) If this repo is ever made public, the original curl-pipe-bash
# one-liner would work too.
#
# Flags:
#   --outbound-iface <iface>   passed through to setup-nat.sh (default:
#                               autodetect via the default route)
#   --skip-smoke-test          skip the final onctl create/destroy round-trip
#   --smoke-vcpu <n>           vCPUs for the smoke-test microVM (default: 2)
#   --smoke-memory <MiB>       memory for the smoke-test microVM (default: 4096)
#                               Lower both on a small host (e.g. 1 / 2048) --
#                               a host can't fit a smoke test bigger than its
#                               own real capacity, and the defaults assume a
#                               normal-sized fc-host, not e.g. a 1-vCPU/3.75GB
#                               GCP n1-standard-1.
set -euo pipefail

IMAGE_DIR=/opt/fc/images
OUTBOUND_IFACE=""
SKIP_SMOKE_TEST=0
SMOKE_VCPU=2
SMOKE_MEMORY=4096

while [ $# -gt 0 ]; do
  case "$1" in
    --outbound-iface) OUTBOUND_IFACE="$2"; shift 2 ;;
    --skip-smoke-test) SKIP_SMOKE_TEST=1; shift ;;
    --smoke-vcpu) SMOKE_VCPU="$2"; shift 2 ;;
    --smoke-memory) SMOKE_MEMORY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

T0=$(date +%s)
say() { echo "[install +$(($(date +%s) - T0))s] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "unsupported arch: $(uname -m) (this repo's published images are amd64-only)" >&2
  exit 1
fi

: "${KERNEL_URL:?missing KERNEL_URL -- mint one with fc-host/scripts/mint-image-links.sh}"
: "${ROOTFS_URL:?missing ROOTFS_URL -- mint one with fc-host/scripts/mint-image-links.sh}"

say "checking for /dev/kvm"
if [ ! -e /dev/kvm ]; then
  echo "/dev/kvm not found — enable VT-x/AMD-V in BIOS (or nested virtualization, if this is itself a VM)" >&2
  exit 1
fi

say "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq iptables iptables-persistent chrony zstd >/dev/null

# A free-running virtual/hardware clock drifting over days of uptime has
# broken GitHub App JWT auth (exp claim past GitHub's 10-min limit) on every
# fc-host that shipped without this.
say "enabling chrony"
systemctl enable --now chrony >/dev/null

say "installing onctl"
if ! command -v onctl >/dev/null 2>&1; then
  curl -sLS https://docs.onctl.io/get.sh | bash >/dev/null
  install onctl /usr/local/bin/onctl
  rm -f onctl
  echo "" >&2
  echo "NOTE: installed the latest PUBLIC onctl release ($(onctl version 2>/dev/null || true))." >&2
  echo "If this host is joining an EXISTING pool (controller/runners.json)," >&2
  echo "its onctl build must match the other pool hosts' exactly -- an older" >&2
  echo "public release has silently ignored an unrecognized flag (exit 0" >&2
  echo "instead of erroring) rather than failing loudly, which made a real" >&2
  echo "onboarding bug (--cache-image on a stale aimax build) very hard to" >&2
  echo "diagnose: see docs/sessions/2026-08-17-aimax-host-onboarding.md, bug #3." >&2
  echo "Copy a known-good binary from an existing pool host instead if so:" >&2
  echo "  scp fc-host:/usr/local/bin/onctl /usr/local/bin/onctl" >&2
  echo "" >&2
else
  say "onctl already installed ($(onctl version 2>/dev/null || true)), skipping"
fi

# `onctl create` refuses to run at all without this, even with every needed
# flag passed explicitly on the command line ("no configuration directory
# found ... Please run `onctl init` first"). Never hit on fc-host/aimax
# since both already had it from years-old manual setup -- only surfaces on
# a genuinely fresh host. Safe to run unconditionally; a no-op if already
# initialized.
say "initializing onctl config"
onctl init

# onctl's fc provider injects this into every microVM's cloud-init and
# defaults to expecting it at exactly this path -- fc-host/aimax already
# had one from years-old manual setup, so this only surfaces on a
# genuinely fresh host.
if [ ! -s /root/.ssh/id_rsa.pub ]; then
  say "generating SSH keypair for onctl (none found)"
  ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q
else
  say "SSH keypair already exists, skipping"
fi

say "installing firecracker binary"
if ! command -v firecracker >/dev/null 2>&1; then
  FC_RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
  FC_LATEST=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$FC_RELEASE_URL/latest")")
  FC_TMP=$(mktemp -d)
  curl -fsSL "$FC_RELEASE_URL/download/$FC_LATEST/firecracker-$FC_LATEST-x86_64.tgz" \
    | tar -xz -C "$FC_TMP"
  install -m 0755 "$FC_TMP/release-$FC_LATEST-x86_64/firecracker-$FC_LATEST-x86_64" /usr/local/bin/firecracker
  rm -rf "$FC_TMP"
  say "installed firecracker $FC_LATEST"
else
  say "firecracker already installed ($(firecracker --version 2>/dev/null | head -1)), skipping"
fi

mkdir -p "$IMAGE_DIR"

# onctl's per-VM rootfs copy uses copy_file_range() reflink cloning, which
# only actually reflinks (near-instant, ~0 extra disk space) on btrfs.
# Everywhere else it falls back to a real byte-for-byte copy of the rootfs
# image's full APPARENT size, not its actual disk usage -- the published
# rootfs is a sparse ext4-filesystem-in-a-file, ~20GB apparent even though
# only a few GB is ever actually written. Every single `onctl create` on a
# non-btrfs host needs that much free space, regardless of how small the
# guest's own --vcpu/--memory is. fc-host/aimax both have a dedicated btrfs
# disk mounted at /opt/fc for exactly this reason (see aimax's
# ~/.onctl/onctl.yaml: `fc.stateDir: /opt/fc`) -- a fresh host won't, and
# the failure mode otherwise is a confusing mid-copy "no space left on
# device" on the first real `onctl create`, not anything caught here.
FC_FSTYPE=$(findmnt -no FSTYPE --target "$IMAGE_DIR" 2>/dev/null || echo unknown)
if [ "$FC_FSTYPE" != "btrfs" ]; then
  echo "" >&2
  echo "WARNING: $IMAGE_DIR is on '$FC_FSTYPE', not btrfs." >&2
  echo "Every 'onctl create' on this host will need ~20GB free space for the" >&2
  echo "rootfs copy alone (see the comment above this check for why) -- even" >&2
  echo "for a 1-vCPU/2GB microVM. If that's not survivable on this disk:" >&2
  echo "  1. attach a separate disk and format it: mkfs.btrfs /dev/<device>" >&2
  echo "  2. mount it at /opt/fc (add to /etc/fstab to survive reboot)" >&2
  echo "  3. set 'stateDir: /opt/fc' under fc: in ~/.onctl/onctl.yaml" >&2
  echo "  4. re-run this script so the images land on the new mount" >&2
  echo "" >&2
fi

DLTMP=$(mktemp -d)
trap 'rm -rf "$DLTMP"' EXIT

say "downloading + decompressing kernel"
curl -fsSL "$KERNEL_URL" | zstd -d -q -o "$DLTMP/vmlinux-overlay2"
mv "$DLTMP/vmlinux-overlay2" "$IMAGE_DIR/vmlinux-overlay2"

say "downloading + decompressing rootfs"
curl -fsSL "$ROOTFS_URL" | zstd -d -q -o "$DLTMP/runner-base-docker.ext4"
mv "$DLTMP/runner-base-docker.ext4" "$IMAGE_DIR/runner-base-docker.ext4"

# fcbr0 doesn't exist yet at this point — onctl creates it on the first
# `onctl create --provider fc` call, further down in the smoke test (or
# later, whenever this host's first real microVM is created). iptables
# accepts a rule referencing an interface that doesn't exist yet; it just
# won't match anything until the bridge appears.
#
# Inlined from setup-nat.sh rather than curled from raw.githubusercontent.com
# -- this repo is private, so an unauthenticated raw fetch 404s. Keeping
# install.sh genuinely self-contained (no sibling-file/public-URL
# dependency) matters more here than not duplicating these dozen lines.
say "setting up outbound NAT"
OUTBOUND_IFACE="${OUTBOUND_IFACE:-$(ip route show default | awk '/default/ {print $5; exit}')}"
echo "==> outbound interface: $OUTBOUND_IFACE"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-fc.conf
sysctl -p /etc/sysctl.d/99-fc.conf
iptables -t nat -A POSTROUTING -o "$OUTBOUND_IFACE" -j MASQUERADE
iptables -A FORWARD -i fcbr0 -o "$OUTBOUND_IFACE" -j ACCEPT
iptables -A FORWARD -i "$OUTBOUND_IFACE" -o fcbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
apt-get install -y -qq iptables-persistent >/dev/null
netfilter-persistent save

if [ "$SKIP_SMOKE_TEST" -eq 0 ]; then
  say "running smoke test (create -> docker run -> destroy), vcpu=$SMOKE_VCPU memory=${SMOKE_MEMORY}MiB"
  onctl create -n fc-install-smoke-test --provider fc --vcpu "$SMOKE_VCPU" --memory "$SMOKE_MEMORY" \
    --kernel-image "$IMAGE_DIR/vmlinux-overlay2" \
    --rootfs-image "$IMAGE_DIR/runner-base-docker.ext4"
  onctl ssh fc-install-smoke-test -- 'docker run --rm hello-world' \
    || { echo "smoke test failed — leaving fc-install-smoke-test up for inspection" >&2; exit 1; }
  onctl destroy fc-install-smoke-test -f
  say "smoke test passed"
else
  say "skipping smoke test"
fi

say "done — host is a working onctl-runner Firecracker host"
echo
echo "Still manual, by design (both touch shared/production state):"
echo "  - reachability for a remote controller to SSH-dispatch here"
echo "    (public IP + firewall rule, or a VPN/tailnet if this box has no"
echo "    public IP -- see docs/sessions/2026-08-17-aimax-host-onboarding.md"
echo "    for why aimax specifically used Tailscale)"
echo "  - authorizing the controller's dispatch SSH key for root here"
echo "  - adding this host to a live controller's runners.json 'hosts'"
echo "    registry and redeploying (controller/scripts/update-control-plane.sh)"
