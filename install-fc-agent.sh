#!/usr/bin/env bash
# Installs fc-agent as a systemd service on this host, so the controller
# can dispatch onctl create/destroy here over HTTPS instead of SSH (see
# docs/plans/fc-host-agent-registration.md). Opt-in and separate from
# bootstrap-host.sh/install.sh, which already stop short of the
# runners.json wiring step for the same reason -- run this only once
# you've decided to flip this specific host's dispatch transport to
# "agent".
#
# Designed to run as a single curl-pipe-bash command, as root: this file
# and its sibling assets (fc-agent.sh, fc-agent.service, github-runner-
# jit.sh) are mirrored to the public github.com/cdalar/onctl-runners-fc-host
# repo by a sync workflow in onctl-runners, reachable at clean onctl.io
# URLs via redirects in onctl-web (see docs/plans/
# fc-host-public-install-repo.md) -- so it fetches those siblings over
# HTTPS rather than assuming a local checkout:
#
#   curl -fsSL https://onctl.io/fc-host-install.sh | sudo env \
#     CONTROLLER_URL=https://runners.onctl.io \
#     HOST_NAME=<the key this host will have in runners.json hosts map> \
#     AGENT_TOKEN=<generate once, e.g. openssl rand -hex 32> \
#       bash
#
# `sudo VAR=x cmd` does NOT set VAR -- sudo would try to run a program
# literally named "VAR=x". `sudo env VAR=x cmd` is the correct idiom: sudo
# runs the real `env` binary as root, which then sets VAR for cmd.
# Already-root shells can drop `sudo env` and just prefix VAR=x directly.
#
# This only sets up the host side. Separately, on the controller side, the
# operator still has to add/update this host's entry in runners.json:
#   "mode": "agent", "agentTokenHash": "<this script's printed sha256sum>"
# and redeploy the controller before the controller will actually route
# any work here.
set -euo pipefail

# Fails fast with a clear message instead of a cryptic `curl: (23) client
# returned ERROR on write` partway through -- every destination below
# (/usr/local/bin, /etc/systemd/system, /root) needs root, and that curl
# write-failure is exactly what "forgot sudo" looks like with no
# indication of why.
if [ "$(id -u)" -ne 0 ]; then
  echo "install-fc-agent.sh must run as root (it writes to /usr/local/bin, /etc/systemd/system, and /root) -- re-run as root, e.g.: sudo env CONTROLLER_URL=... HOST_NAME=... AGENT_TOKEN=... bash install-fc-agent.sh" >&2
  exit 1
fi

: "${CONTROLLER_URL:?CONTROLLER_URL is required (e.g. https://runners.onctl.io)}"
: "${HOST_NAME:?HOST_NAME is required (the key this host will have in runners.json hosts map)}"
: "${AGENT_TOKEN:?AGENT_TOKEN is required (generate once, e.g. with: openssl rand -hex 32)}"
# Overridable so a maintainer can point this at a fork/branch while
# testing changes before they're synced to the real public repo. Points at
# onctl.io's redirects (onctl-web's next.config.ts), not the raw GitHub
# URL directly, so every file fetched below goes through one clean,
# stable domain -- see docs/plans/fc-host-public-install-repo.md.
RAW_BASE_URL="${RAW_BASE_URL:-https://onctl.io}"

curl -fsSL "${RAW_BASE_URL}/fc-agent.sh" -o /usr/local/bin/fc-agent.sh
chmod 0755 /usr/local/bin/fc-agent.sh

mkdir -p /etc/onctl-fc-agent
cat >/etc/onctl-fc-agent/env <<EOF
CONTROLLER_URL=${CONTROLLER_URL}
HOST_NAME=${HOST_NAME}
AGENT_TOKEN=${AGENT_TOKEN}
EOF
# The env file holds AGENT_TOKEN in the clear -- same trust level as
# runners.json's WEBHOOK_SECRET/DASHBOARD_API_TOKEN on the controller side,
# root-only permissions, no group/other read.
chmod 0600 /etc/onctl-fc-agent/env

curl -fsSL "${RAW_BASE_URL}/fc-agent.service" -o /etc/systemd/system/fc-agent.service
chmod 0644 /etc/systemd/system/fc-agent.service

# github-runner-jit.sh is what `onctl create -a` actually runs on the
# guest; production profiles reference it at this exact absolute path.
# Nothing else in this repo places it here automatically today (a real
# gap found while testing this feature against a real host) -- never
# overwritten if already present, so a host with its own customized copy
# keeps it.
if [ ! -f /root/github-runner-jit.sh ]; then
  echo "fetching github-runner-jit.sh to /root/github-runner-jit.sh (missing)"
  curl -fsSL "${RAW_BASE_URL}/github-runner-jit.sh" -o /root/github-runner-jit.sh
  chmod 0755 /root/github-runner-jit.sh
else
  echo "/root/github-runner-jit.sh already present, leaving it as-is"
fi

systemctl daemon-reload
systemctl enable --now fc-agent

echo "fc-agent installed and started. Check status with:"
echo "  systemctl status fc-agent"
echo "  journalctl -u fc-agent -f"
echo
echo "sha256 of AGENT_TOKEN, for this host's agentTokenHash in runners.json:"
printf '%s' "${AGENT_TOKEN}" | sha256sum | awk '{print $1}'
