#!/usr/bin/env bash
# Installs fc-agent as a systemd service on this host, so the controller
# can dispatch onctl create/destroy here over HTTPS instead of SSH (see
# docs/plans/fc-host-agent-registration.md). Opt-in and separate from
# bootstrap-host.sh/install.sh, which already stop short of the
# runners.json wiring step for the same reason -- run this only once
# you've decided to flip this specific host's dispatch transport to
# "agent".
#
# Designed to run as a single curl-pipe-bash command: this file and its
# two sibling assets (fc-agent.sh, fc-agent.service) are mirrored to the
# public github.com/cdalar/onctl-runners-fc-host repo by a sync workflow in
# onctl-runners (see docs/plans/fc-host-public-install-repo.md), so it
# fetches those siblings over HTTPS rather than assuming a local checkout:
#
#   curl -fsSL https://raw.githubusercontent.com/cdalar/onctl-runners-fc-host/main/install-fc-agent.sh | \
#     CONTROLLER_URL=https://runners.onctl.io \
#     HOST_NAME=<the key this host will have in runners.json hosts map> \
#     AGENT_TOKEN=<generate once, e.g. openssl rand -hex 32> \
#       bash
#
# This only sets up the host side. Separately, on the controller side, the
# operator still has to add/update this host's entry in runners.json:
#   "mode": "agent", "agentTokenHash": "<this script's printed sha256sum>"
# and redeploy the controller before the controller will actually route
# any work here.
set -euo pipefail

: "${CONTROLLER_URL:?CONTROLLER_URL is required (e.g. https://runners.onctl.io)}"
: "${HOST_NAME:?HOST_NAME is required (the key this host will have in runners.json hosts map)}"
: "${AGENT_TOKEN:?AGENT_TOKEN is required (generate once, e.g. with: openssl rand -hex 32)}"
# Overridable so a maintainer can point this at a fork/branch while
# testing changes before they're synced to the real public repo.
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/cdalar/onctl-runners-fc-host/main}"

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
