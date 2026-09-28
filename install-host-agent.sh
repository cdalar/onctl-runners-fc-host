#!/usr/bin/env bash
# Installs onctl-host-agent as a systemd service on this host, so the controller
# can dispatch onctl create/destroy here over HTTPS instead of SSH (see
# docs/plans/fc-host-agent-registration.md). Opt-in and separate from
# bootstrap-host.sh/install.sh, which already stop short of the
# runners.json wiring step for the same reason -- run this only once
# you've decided to flip this specific host's dispatch transport to
# "agent".
#
# Designed to run as a single curl-pipe-bash command, AS ROOT, with no
# required env vars in the common case: this file and its sibling assets
# (onctl-host-agent.sh, onctl-host-agent.service, github-runner-jit.sh) are
# mirrored to the
# public github.com/cdalar/onctl-runners-fc-host repo by a sync workflow in
# onctl-runners, reachable at clean onctl.io URLs via redirects in
# onctl-web (see docs/plans/fc-host-public-install-repo.md) -- so it
# fetches those siblings over HTTPS rather than assuming a local checkout.
# If you're not already root, become root first (e.g. `sudo -i`) rather
# than trying to wedge `sudo` into the command below -- `sudo VAR=x cmd`
# does not actually set VAR (sudo would try to run a program literally
# named "VAR=x"), which makes combining sudo with env var overrides on a
# piped one-liner needlessly fiddly to get right:
#
#   curl -fsSL https://onctl.io/install-host-agent.sh | bash
#
# CONTROLLER_URL/HOST_NAME/AGENT_TOKEN all have sensible defaults (below)
# and only need overriding for a non-default setup:
#
#   curl -fsSL https://onctl.io/install-host-agent.sh | \
#     HOST_NAME=<the key this host will have in runners.json hosts map> \
#       bash
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
  echo "install-host-agent.sh must run as root (it writes to /usr/local/bin, /etc/systemd/system, and /root) -- become root first (e.g. sudo -i) and re-run" >&2
  exit 1
fi

ENV_FILE=/etc/onctl-host-agent/env

# The agent was called fc-agent until 2026-09 (fc-agent.sh, fc-agent.service,
# /etc/onctl-fc-agent/env). A host installed under that name is migrated in
# place further down; until then its env file is where this host's existing
# identity lives.
LEGACY_UNIT=fc-agent
LEGACY_BIN=/usr/local/bin/fc-agent.sh
LEGACY_UNIT_FILE=/etc/systemd/system/fc-agent.service
LEGACY_ENV_FILE=/etc/onctl-fc-agent/env

EXISTING_ENV_FILE=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_ENV_FILE="$ENV_FILE"
elif [ -f "$LEGACY_ENV_FILE" ]; then
  EXISTING_ENV_FILE="$LEGACY_ENV_FILE"
  echo "found a legacy fc-agent install ($LEGACY_ENV_FILE) -- will migrate it to onctl-host-agent"
fi

# existing_env KEY: that key's value from this host's existing env file, or
# empty. Never fails (set -e) when the file or the key is missing.
existing_env() {
  [ -n "$EXISTING_ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$EXISTING_ENV_FILE"
}

# Idempotent, same reasoning as AGENT_TOKEN below: a re-run without env
# overrides must keep pointing this host at the same controller under the
# same name. Re-deriving HOST_NAME from `hostname` on a host first installed
# with an explicit HOST_NAME=... would silently rename it out of
# runners.json's "hosts" map.
if [ -z "${CONTROLLER_URL:-}" ]; then
  CONTROLLER_URL="$(existing_env CONTROLLER_URL)"
fi
CONTROLLER_URL="${CONTROLLER_URL:-https://runners.onctl.io}"

# Sanitized to the same charset every existing runners.json host key
# already uses (lowercase alphanumeric + dashes) -- a raw `hostname` can
# have dots, underscores, or mixed case that would otherwise land in
# runners.json's "hosts" map looking unlike every other entry there.
if [ -z "${HOST_NAME:-}" ]; then
  HOST_NAME="$(existing_env HOST_NAME)"
fi
if [ -z "${HOST_NAME:-}" ]; then
  HOST_NAME="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
fi
: "${HOST_NAME:?could not derive a host name from \`hostname\` -- set HOST_NAME explicitly}"

# Idempotent, not just auto-generated: re-running this script (e.g. to
# pick up a newer onctl-host-agent) must NOT silently rotate the token, or the
# host's existing runners.json agentTokenHash would stop matching and it'd
# quietly fall out of the pool. Reuse whatever's already on disk unless the
# caller explicitly passes a different AGENT_TOKEN.
if [ -z "${AGENT_TOKEN:-}" ]; then
  AGENT_TOKEN="$(existing_env AGENT_TOKEN)"
  if [ -n "$AGENT_TOKEN" ]; then
    echo "reusing existing AGENT_TOKEN from $EXISTING_ENV_FILE (re-run detected)"
  fi
fi
if [ -z "${AGENT_TOKEN:-}" ]; then
  AGENT_TOKEN="$(openssl rand -hex 32)"
  echo "generated a new AGENT_TOKEN"
fi

# Overridable so a maintainer can point this at a fork/branch while
# testing changes before they're synced to the real public repo. Points at
# onctl.io's redirects (onctl-web's next.config.ts), not the raw GitHub
# URL directly, so every file fetched below goes through one clean,
# stable domain -- see docs/plans/fc-host-public-install-repo.md.
RAW_BASE_URL="${RAW_BASE_URL:-https://onctl.io}"

# Fetch everything before touching the running install: a missing file
# (e.g. onctl.io's redirects not deployed yet for a renamed asset) must
# fail here, with the old agent still up, not halfway through a migration.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
curl -fsSL "${RAW_BASE_URL}/onctl-host-agent.sh" -o "$STAGE_DIR/onctl-host-agent"
curl -fsSL "${RAW_BASE_URL}/onctl-host-agent.service" -o "$STAGE_DIR/onctl-host-agent.service"

# Stop a legacy fc-agent BEFORE the new unit starts: both would register
# under the same HOST_NAME/token and race each other for this host's jobs.
# Its unit has KillMode=process, so running microVMs survive the stop; a
# create/destroy it was in the middle of does not report back (same as any
# `systemctl restart` of the agent) -- migrate an idle host when you can.
if [ -f "$LEGACY_UNIT_FILE" ] || [ -f "$LEGACY_BIN" ]; then
  echo "migrating legacy fc-agent install to onctl-host-agent"
  systemctl disable --now "$LEGACY_UNIT" 2>/dev/null || true
  # KillMode=process only signals the main PID; reap the legacy heartbeat
  # subshell too so it doesn't keep heartbeating alongside the new agent.
  pkill -f "$LEGACY_BIN" 2>/dev/null || true
  rm -f "$LEGACY_UNIT_FILE" "$LEGACY_BIN"
fi

install -m 0755 "$STAGE_DIR/onctl-host-agent" /usr/local/bin/onctl-host-agent

mkdir -p "$(dirname "$ENV_FILE")"
cat >"$ENV_FILE" <<EOF
CONTROLLER_URL=${CONTROLLER_URL}
HOST_NAME=${HOST_NAME}
AGENT_TOKEN=${AGENT_TOKEN}
EOF
# The env file holds AGENT_TOKEN in the clear -- same trust level as
# runners.json's WEBHOOK_SECRET/DASHBOARD_API_TOKEN on the controller side,
# root-only permissions, no group/other read.
chmod 0600 "$ENV_FILE"
# Only once the token is safely in the new env file.
rm -rf "$(dirname "$LEGACY_ENV_FILE")"

install -m 0644 "$STAGE_DIR/onctl-host-agent.service" /etc/systemd/system/onctl-host-agent.service

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
systemctl enable onctl-host-agent
# restart, not just `enable --now`: on a re-run the unit is already active,
# and --now would leave the old script running.
systemctl restart onctl-host-agent

echo "onctl-host-agent installed and started. Check status with:"
echo "  systemctl status onctl-host-agent"
echo "  journalctl -u onctl-host-agent -f"
echo
echo "HOST_NAME: ${HOST_NAME} (this must be the key used in runners.json's \"hosts\" map)"
echo "sha256 of AGENT_TOKEN, for this host's agentTokenHash in runners.json:"
printf '%s' "${AGENT_TOKEN}" | sha256sum | awk '{print $1}'
