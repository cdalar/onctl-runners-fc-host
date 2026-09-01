#!/usr/bin/env bash
# One-shot bring-up for a bare-metal box as a new onctl-runner Firecracker
# host: packages, onctl, the firecracker binary, kernel/rootfs images,
# outbound NAT, and (optionally) a smoke-test microVM — everything short of
# wiring the host into a live controller's runners.json (that's a
# production-config change, done separately once this box is verified).
#
# If a build has already been published to R2 (publish-image.sh), prefer
# install.sh instead of this script -- it downloads the prebaked images via
# a presigned URL instead of building them locally (this script's default,
# ~15-20 min) or requiring another host reachable over SSH (--source-host
# below). This script is still the right tool for the *first* host ever
# (nothing published yet to pull from) or for rebuilding images from
# scratch on a box you'll then publish from.
#
# Run ON the new host, as root, from a checkout of this repo:
#   scp -r fc-host <new-host>:/root/
#   ssh <new-host> bash /root/fc-host/scripts/bootstrap-host.sh [flags]
#
# By default, builds the kernel and rootfs images locally (~15-20 min:
# build-fc-kernel.sh + bake-fc-image.sh, both sibling scripts) and installs
# onctl from the latest public release. Pass --source-host to instead copy
# the already-built images *and* the onctl binary from an existing fc-host
# over SSH — much faster, and guarantees byte-identical images/onctl builds,
# which matters if this host is joining an existing pool where every host
# must behave identically against the same runners.json args
# (--kernel-image/--rootfs-image paths, and any onctl flag a profile passes,
# are shared across the whole pool, not per-host).
#
# Flags:
#   --source-host <ssh-host>   rsync vmlinux-overlay2 + runner-base-docker.ext4
#                              (from <ssh-host>:/opt/fc/images/) and the
#                              onctl binary (from <ssh-host>:/usr/local/bin/)
#                              instead of building/installing them locally
#   --outbound-iface <iface>  passed through to setup-nat.sh (default:
#                              autodetect via the default route)
#   --skip-smoke-test         skip the final onctl create/destroy round-trip
#   --smoke-vcpu <n>          vCPUs for the smoke-test microVM (default: 2)
#   --smoke-memory <MiB>      memory for the smoke-test microVM (default: 4096)
#                              Lower both on a small host -- a host can't fit
#                              a smoke test bigger than its own real capacity.
#
# The local rootfs bake (bake-fc-image.sh) picks its own apt mirror based on
# this host's network — no flag needed here, see that script's MIRROR
# selection.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE_DIR=/opt/fc/images

SOURCE_HOST=""
OUTBOUND_IFACE=""
SKIP_SMOKE_TEST=0
SMOKE_VCPU=2
SMOKE_MEMORY=4096

while [ $# -gt 0 ]; do
  case "$1" in
    --source-host) SOURCE_HOST="$2"; shift 2 ;;
    --outbound-iface) OUTBOUND_IFACE="$2"; shift 2 ;;
    --skip-smoke-test) SKIP_SMOKE_TEST=1; shift ;;
    --smoke-vcpu) SMOKE_VCPU="$2"; shift 2 ;;
    --smoke-memory) SMOKE_MEMORY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

T0=$(date +%s)
say() { echo "[bootstrap-host +$(($(date +%s) - T0))s] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "unsupported arch: $(uname -m) (this repo's baked images are amd64-only)" >&2
  exit 1
fi

say "checking for /dev/kvm"
if [ ! -e /dev/kvm ]; then
  echo "/dev/kvm not found — enable VT-x/AMD-V in BIOS (or nested virtualization, if this is itself a VM)" >&2
  exit 1
fi

say "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq iptables iptables-persistent chrony e2fsprogs debootstrap >/dev/null

# A free-running virtual/hardware clock drifting over days of uptime has
# broken GitHub App JWT auth (exp claim past GitHub's 10-min limit) on every
# fc-host that shipped without this.
say "enabling chrony"
systemctl enable --now chrony >/dev/null

# debootstrap fetches packages via wget, which — like most tools — prefers
# IPv6 when the host has an address, even when that path is actually broken
# or badly congested (seen firsthand: a wget stuck for minutes on one
# package, dead IPv6 socket, while plain curl calls elsewhere in the same
# run succeeded fine over IPv4). Forcing IPv4 here avoids that whole class
# of silent stall on networks with flaky IPv6 — e.g. a home/office LAN,
# unlike a datacenter host with well-behaved IPv6.
say "forcing IPv4 for wget (avoids stalling on broken IPv6 paths during debootstrap)"
grep -q '^inet4-only = on$' /etc/wgetrc 2>/dev/null || echo 'inet4-only = on' >> /etc/wgetrc

if [ -n "$SOURCE_HOST" ]; then
  # Byte-identical onctl matters here for the same reason the kernel/rootfs
  # images below need to be: every host in a pool must behave identically
  # against the same runners.json args. Skew bit hard once already — a host
  # running an older public onctl release silently ignored an unrecognized
  # --cache-image flag (exit 0 instead of erroring) while the rest of the
  # pool ran a newer build that supports it, so `onctl create` quietly did
  # nothing: the controller logged "onctl create done", no VM ever existed,
  # and the job just timed out after 5 minutes with no error anywhere. Copy
  # the exact binary a known-good pool host already runs instead of
  # re-resolving "latest" independently on every new host.
  say "copying onctl binary from $SOURCE_HOST (avoids pool version skew)"
  rsync -avP "$SOURCE_HOST:/usr/local/bin/onctl" /usr/local/bin/onctl
  chmod 0755 /usr/local/bin/onctl
else
  say "installing onctl (no --source-host given, using latest public release)"
  if ! command -v onctl >/dev/null 2>&1; then
    # No --source-host means there's no known-good pool build to match, so
    # this falls back to whatever's latest public. If this host is meant to
    # join an *existing* pool, re-run with --source-host instead — see the
    # skew warning above for why that matters once a profile uses
    # --cache-image or any other flag not every onctl release recognizes.
    curl -sLS https://docs.onctl.io/get.sh | bash >/dev/null
    install onctl /usr/local/bin/onctl
    rm -f onctl
  else
    say "onctl already installed ($(onctl version 2>/dev/null || true)), skipping"
  fi
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
# image's full APPARENT size, not its actual disk usage -- the baked rootfs
# is a sparse ext4-filesystem-in-a-file, tens of GB apparent even though only
# a few GB is ever actually written. Every single `onctl create` on a
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
  echo "Every 'onctl create' on this host will need enough free space for the" >&2
  echo "rootfs image's full apparent size (see the comment above this check)" >&2
  echo "-- even for a small microVM. If that's not survivable on this disk:" >&2
  echo "  1. attach a separate disk and format it: mkfs.btrfs /dev/<device>" >&2
  echo "  2. mount it at /opt/fc (add to /etc/fstab to survive reboot)" >&2
  echo "  3. set 'stateDir: /opt/fc' under fc: in ~/.onctl/onctl.yaml" >&2
  echo "  4. re-run this script so the images land on the new mount" >&2
  echo "" >&2
fi

if [ -n "$SOURCE_HOST" ]; then
  say "copying kernel + rootfs images from $SOURCE_HOST"
  rsync -avP \
    "$SOURCE_HOST:$IMAGE_DIR/vmlinux-overlay2" \
    "$SOURCE_HOST:$IMAGE_DIR/runner-base-docker.ext4" \
    "$IMAGE_DIR/"
else
  if [ -s "$IMAGE_DIR/vmlinux-overlay2" ]; then
    say "$IMAGE_DIR/vmlinux-overlay2 already exists, skipping kernel build"
  else
    say "building kernel locally (build-fc-kernel.sh, ~10-15 min)"
    bash "$SCRIPT_DIR/build-fc-kernel.sh"
  fi
  if [ -s "$IMAGE_DIR/runner-base-docker.ext4" ]; then
    say "$IMAGE_DIR/runner-base-docker.ext4 already exists, skipping rootfs bake"
  else
    say "baking rootfs locally (bake-fc-image.sh, ~5-10 min)"
    bash "$SCRIPT_DIR/bake-fc-image.sh"
  fi
fi

# fcbr0 doesn't exist yet at this point — onctl creates it on the first
# `onctl create --provider fc` call, further down in the smoke test (or
# later, whenever this host's first real microVM is created). iptables
# accepts a rule referencing an interface that doesn't exist yet; it just
# won't match anything until the bridge appears.
say "setting up outbound NAT"
bash "$SCRIPT_DIR/setup-nat.sh" ${OUTBOUND_IFACE:+"$OUTBOUND_IFACE"}

say "isolating microVMs from each other on fcbr0 (multi-tenant: no VM-to-VM traffic)"
bash "$SCRIPT_DIR/setup-fc-bridge-isolation.sh"

if [ "$SKIP_SMOKE_TEST" -eq 0 ]; then
  say "running smoke test (create -> docker run -> destroy), vcpu=$SMOKE_VCPU memory=${SMOKE_MEMORY}MiB"
  onctl create -n fc-bootstrap-smoke-test --provider fc --vcpu "$SMOKE_VCPU" --memory "$SMOKE_MEMORY" \
    --kernel-image "$IMAGE_DIR/vmlinux-overlay2" \
    --rootfs-image "$IMAGE_DIR/runner-base-docker.ext4"
  onctl ssh fc-bootstrap-smoke-test -- 'docker run --rm hello-world' \
    || { echo "smoke test failed — leaving fc-bootstrap-smoke-test up for inspection" >&2; exit 1; }
  onctl destroy fc-bootstrap-smoke-test -f
  say "smoke test passed"
else
  say "skipping smoke test"
fi

say "done — host is a working onctl-runner Firecracker host"
echo
echo "Still manual, by design (both touch shared/production state):"
echo "  - reachability for a remote controller to SSH-dispatch here (e.g. Tailscale),"
echo "    if this host has no public IP/port-forward"
echo "  - adding this host to a live controller's runners.json 'hosts' registry"
echo "    and redeploying (controller/scripts/update-control-plane.sh)"
