#!/usr/bin/env bash
# Bootstrap a GitHub Actions runner via JIT config on a fresh Ubuntu VM.
# Designed to run as root via `onctl create -a`.
#
# Required vars (pass with -e):
#   JIT_CONFIG    base64 JIT config blob, generate with:
#                 gh api -X POST repos/$GH_REPO/actions/runners/generate-jitconfig \
#                   -f name=runner-spike-jit -F runner_group_id=1 \
#                   -f 'labels[]=self-hosted' -f 'labels[]=onctl' \
#                   -q .encoded_jit_config
# Optional vars:
#   SKIP_DOCKER   set to 1 to skip docker install (faster boot measurement)
#   RUNNER_NAME   sets the guest OS hostname to this value (defaults to
#                 "onctl-runner"). The controller passes its gh-runner-<jobid>
#                 runner name here so a job's "Machine name" in its own
#                 Actions log matches the Runner shown on the dashboard,
#                 instead of leaking the baked image's real pool-host
#                 hostname (see debootstrap UTS-namespace note below).
#
# When run on a prebaked image (created by scripts/bake-image.sh), docker
# and the runner binary are already present — those steps are skipped
# automatically.
set -euo pipefail

T0=$(date +%s)
say() { echo "[github-runner-jit +$(($(date +%s) - T0))s] $*"; }

JIT_CONFIG="${JIT_CONFIG:?JIT_CONFIG is required, pass with -e JIT_CONFIG=...}"
RUNNER_USER=runner
RUNNER_HOME=/opt/actions-runner

# debootstrap (bake-fc-image.sh) runs in a chroot that doesn't isolate the
# UTS namespace, so baked images carry the pool host's real hostname in
# /etc/hostname. The actions-runner prints that verbatim as "Machine name"
# in every job's "Set up job" log, leaking the physical host's identity
# into CI logs (including public repos). Reset it here — using the same
# gh-runner-<jobid> name the controller already registered this runner
# under (RUNNER_NAME, passed alongside JIT_CONFIG) rather than a generic
# placeholder — so the value stays unique per VM and matches what's already
# shown on the dashboard (job.RunnerName / activityEvent.Runner), letting
# an operator pinpoint which run a "Machine name" in a job log corresponds
# to without exposing which physical pool host it actually ran on. Falls
# back to a generic name if RUNNER_NAME is unset (e.g. manual `onctl create`
# runs of this script outside the controller).
RUNNER_HOSTNAME="${RUNNER_NAME:-onctl-runner}"
say "resetting hostname to ${RUNNER_HOSTNAME} (baked image carries the pool host's real hostname)"
echo "$RUNNER_HOSTNAME" > /etc/hostname
hostname "$RUNNER_HOSTNAME" 2>/dev/null || true
grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null || echo -e "127.0.1.1\t${RUNNER_HOSTNAME}" >> /etc/hosts

if [ -f /opt/.baked ]; then
    say "baked image detected — skipping package install, docker install, and user setup"
else
    say "installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq git tar >/dev/null

    if [ "${SKIP_DOCKER:-0}" != "1" ] && ! command -v docker &>/dev/null; then
        say "installing docker"
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    else
        say "docker already present, skipping install"
    fi

    say "creating ${RUNNER_USER} user"
    if ! id "$RUNNER_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$RUNNER_USER"
    fi
    getent group docker >/dev/null 2>&1 && usermod -aG docker "$RUNNER_USER"
fi

if [ ! -f "$RUNNER_HOME/run.sh" ]; then
    say "downloading actions-runner"
    case "$(uname -m)" in
        x86_64)  ARCH=x64 ;;
        aarch64) ARCH=arm64 ;;
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
    VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name | ltrimstr("v")')
    mkdir -p "$RUNNER_HOME"
    curl -fsSL "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${ARCH}-${VERSION}.tar.gz" \
        | tar xz -C "$RUNNER_HOME"
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
else
    say "actions-runner already present, skipping download"
fi


say "starting runner via JIT config in background (ephemeral: exits after one job)"
cd "$RUNNER_HOME"
sudo -u "$RUNNER_USER" bash -c "nohup ./run.sh --jitconfig '$JIT_CONFIG' > '$RUNNER_HOME/jit-run.log' 2>&1 &"

say "runner launched, no service installed"
