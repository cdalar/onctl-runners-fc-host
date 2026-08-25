#!/usr/bin/env bash
# fc-agent: long-running daemon for an fc-host configured with "mode":
# "agent" in the controller's runners.json (docs/plans/fc-host-agent-
# registration.md). Registers with the controller once, heartbeats
# periodically, and long-polls for onctl create/destroy work instead of
# the controller SSHing in to run those commands itself — see
# controller/README.md's "Dispatch transport: SSH vs fc-agent" section for
# the exact endpoints this talks to. Meant to run under systemd
# (fc-agent.service, installed by install-fc-agent.sh), not interactively.
#
# Required env (see fc-agent.service's EnvironmentFile):
#   CONTROLLER_URL  e.g. https://runners.onctl.io
#   HOST_NAME       must match this host's key in runners.json's "hosts" map
#   AGENT_TOKEN     raw bearer token; runners.json stores only its sha256
#                    hex digest (AgentTokenHash) -- see install-fc-agent.sh
# Optional:
#   HEARTBEAT_INTERVAL_SECONDS  default 15
set -euo pipefail

: "${CONTROLLER_URL:?CONTROLLER_URL is required (e.g. https://runners.onctl.io)}"
: "${HOST_NAME:?HOST_NAME is required (must match the hosts map key in runners.json for this host)}"
: "${AGENT_TOKEN:?AGENT_TOKEN is required (the raw token whose sha256 must equal this hosts agentTokenHash in runners.json)}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-15}"
AGENT_VERSION="${AGENT_VERSION:-dev}"

log() { echo "[fc-agent] $*" >&2; }

auth_header=(-H "Authorization: Bearer ${AGENT_TOKEN}")

register() {
  curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
    "${auth_header[@]}" -H 'Content-Type: application/json' \
    -d "{\"version\":\"${AGENT_VERSION}\"}" \
    "${CONTROLLER_URL}/hosts/${HOST_NAME}/register"
}

# Retry registration rather than failing out: a host and the controller
# don't necessarily come up in a guaranteed order (e.g. both rebooting
# after a shared power event), and systemd will otherwise just restart a
# crash-looping unit anyway -- looping here is quieter and faster to
# recover than relying on Restart=/RestartSec= alone.
until code=$(register) && [ "$code" = "204" ]; do
  log "register failed (http ${code:-?}), retrying in 5s"
  sleep 5
done
log "registered with ${CONTROLLER_URL} as ${HOST_NAME}"

# Runs independently of the long-poll loop below so a host stays "live" in
# GET /queue's agent_hosts view even while a single create/destroy call is
# mid-flight (onctl create can take minutes) -- the long-poll itself only
# doubles as a heartbeat between jobs, not during one.
heartbeat_loop() {
  while true; do
    sleep "${HEARTBEAT_INTERVAL_SECONDS}"
    curl -sS -m 15 -o /dev/null -X POST "${auth_header[@]}" \
      "${CONTROLLER_URL}/hosts/${HOST_NAME}/heartbeat" || log "heartbeat failed"
  done
}
heartbeat_loop &
heartbeat_pid=$!
# SIGKILL can't be trapped -- an orphaned heartbeat loop from a killed
# fc-agent is a cosmetic annoyance (a few failed curls to a host that's
# going away anyway), not a resource leak, so this is best-effort cleanup
# rather than something requiring a process-group kill.
trap 'kill "$heartbeat_pid" 2>/dev/null || true' EXIT

# run_job executes one claimed job (job_json: {id, bin, args, env}) as a
# local subprocess and reports {output, error} back -- output is base64
# because the controller's agentJobResult.Output is a Go []byte field,
# which encoding/json marshals/unmarshals as base64 on the wire.
run_job() {
  local job_json="$1"
  local id bin
  id=$(jq -r '.id' <<<"$job_json")
  bin=$(jq -r '.bin' <<<"$job_json")

  local -a args=()
  while IFS= read -r a; do args+=("$a"); done < <(jq -r '.args[]? // empty' <<<"$job_json")

  local -a env_assignments=()
  while IFS= read -r kv; do env_assignments+=("$kv"); done < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$job_json")

  log "running job ${id}: ${bin} ${args[*]:-}"
  local output status=0
  output=$(env "${env_assignments[@]}" "$bin" "${args[@]}" 2>&1) || status=$?
  log "job ${id}: exec finished, status=${status}"

  local err_msg=""
  if [ "$status" -ne 0 ]; then
    err_msg="exit status ${status}"
    log "job ${id} failed: ${err_msg}"
  fi

  local result_json
  result_json=$(jq -n \
    --arg output "$(printf '%s' "$output" | base64 | tr -d '\n')" \
    --arg err "$err_msg" \
    '{output: $output, error: $err}')

  log "job ${id}: posting result"
  local result_code
  result_code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST "${auth_header[@]}" -H 'Content-Type: application/json' \
    -d "$result_json" "${CONTROLLER_URL}/hosts/${HOST_NAME}/jobs/${id}/result") || result_code="curl-failed"
  log "job ${id}: result post finished, http=${result_code}"
}

log "polling for work"
while true; do
  if ! resp=$(curl -sS -m 40 -w '\n%{http_code}' "${auth_header[@]}" \
    "${CONTROLLER_URL}/hosts/${HOST_NAME}/jobs/next"); then
    log "jobs/next request failed, retrying in 5s"
    sleep 5
    continue
  fi
  http_code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http_code" in
  200)
    run_job "$body"
    ;;
  204)
    : # no job waiting -- poll again immediately
    ;;
  *)
    log "jobs/next returned http ${http_code}, retrying in 5s"
    sleep 5
    ;;
  esac
done
