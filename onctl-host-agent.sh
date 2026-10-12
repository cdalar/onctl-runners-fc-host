#!/usr/bin/env bash
# onctl-host-agent (called fc-agent until 2026-09): long-running daemon for
# an fc-host configured with "mode": "agent" in the controller's
# runners.json (docs/plans/fc-host-agent-registration.md). Registers with
# the controller once, heartbeats periodically, and long-polls for onctl
# create/destroy work instead of the controller SSHing in to run those
# commands itself — see controller/README.md's "Dispatch transport: SSH vs
# onctl-host-agent" section for the exact endpoints this talks to. Meant to
# run under systemd
# (onctl-host-agent.service, installed by install-host-agent.sh), not
# interactively.
#
# Required env (see onctl-host-agent.service's EnvironmentFile):
#   CONTROLLER_URL  e.g. https://runners.onctl.io
#   HOST_NAME       must match this host's key in runners.json's "hosts" map
#   AGENT_TOKEN     raw bearer token; runners.json stores only its sha256
#                    hex digest (AgentTokenHash) -- see install-host-agent.sh
# Optional:
#   HEARTBEAT_INTERVAL_SECONDS  default 15
#   MAX_PARALLEL_JOBS           default 4; how many claimed jobs (onctl
#                               create/destroy) run at once
set -euo pipefail

: "${CONTROLLER_URL:?CONTROLLER_URL is required (e.g. https://runners.onctl.io)}"
: "${HOST_NAME:?HOST_NAME is required (must match the hosts map key in runners.json for this host)}"
: "${AGENT_TOKEN:?AGENT_TOKEN is required (the raw token whose sha256 must equal this hosts agentTokenHash in runners.json)}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-15}"
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-4}"
AGENT_VERSION="${AGENT_VERSION:-dev}"

log() { echo "[onctl-host-agent] $*" >&2; }

# agent_curl is curl plus this host's bearer token. The header goes in as a
# curl config on stdin (-K -), never as -H on the command line: argv is
# readable by every local user via ps / /proc/<pid>/cmdline, and the
# jobs/next long-poll below is alive essentially all the time -- so the
# token used to just sit there. It lets its holder claim this host's jobs
# (runner JIT configs included) from the controller. This process's
# environment, where AGENT_TOKEN itself lives, is only readable by root.
# A here-string, not a header file on disk, so there's nothing to clean up.
# Consequence: stdin is taken -- pass request bodies with -d "<string>",
# never @-.
agent_curl() {
  curl -K - "$@" <<<"header = \"Authorization: Bearer ${AGENT_TOKEN}\""
}

register() {
  agent_curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
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
    agent_curl -sS -m 15 -o /dev/null -X POST \
      "${CONTROLLER_URL}/hosts/${HOST_NAME}/heartbeat" || log "heartbeat failed"
  done
}
heartbeat_loop &
heartbeat_pid=$!
# SIGKILL can't be trapped -- an orphaned heartbeat loop from a killed
# onctl-host-agent is a cosmetic annoyance (a few failed curls to a host that's
# going away anyway), not a resource leak, so this is best-effort cleanup
# rather than something requiring a process-group kill.
trap 'kill "$heartbeat_pid" 2>/dev/null || true' EXIT

# run_job executes one claimed job (job_json: {id, bin, args, env}) as a
# local subprocess and reports {output, error} back -- output is base64
# because the controller's agentJobResult.Output is a Go []byte field,
# which encoding/json marshals/unmarshals as base64 on the wire.
# after_pid, if set, is an earlier job for the same microVM that must
# finish first (see the poll loop below).
run_job() {
  local job_json="$1" after_pid="${2:-}"
  local id bin
  id=$(jq -r '.id' <<<"$job_json")
  bin=$(jq -r '.bin' <<<"$job_json")

  if [ -n "$after_pid" ] && kill -0 "$after_pid" 2>/dev/null; then
    log "job ${id}: waiting for an earlier job on the same microVM (pid ${after_pid})"
    while kill -0 "$after_pid" 2>/dev/null; do sleep 0.2; done
  fi

  local -a args=()
  while IFS= read -r a; do args+=("$a"); done < <(jq -r '.args[]? // empty' <<<"$job_json")

  local -a env_assignments=()
  while IFS= read -r kv; do env_assignments+=("$kv"); done < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$job_json")

  # Log the command with every `-e KEY=VALUE` value masked: for a create
  # that's JIT_CONFIG, the runner's GitHub credential (RSA private key
  # included), and this log line lands in journald on the host. Keys stay
  # visible; masking all -e values rather than just JIT_CONFIG means a
  # future secret passed the same way doesn't need its own rule here.
  local -a log_args=()
  local prev_arg=""
  for a in "${args[@]}"; do
    if { [ "$prev_arg" = "-e" ] || [ "$prev_arg" = "--env" ]; } && [[ "$a" == *=* ]]; then
      log_args+=("${a%%=*}=<redacted>")
    else
      log_args+=("$a")
    fi
    prev_arg="$a"
  done
  log "running job ${id}: ${bin} ${log_args[*]:-}"
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
  local result_file
  result_file=$(mktemp)
  local result_code
  result_code=$(agent_curl -sS -m 15 -o "$result_file" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$result_json" "${CONTROLLER_URL}/hosts/${HOST_NAME}/jobs/${id}/result") || result_code="curl-failed"
  log "job ${id}: result post finished, http=${result_code}"

  local abandoned="false"
  if [ -s "$result_file" ]; then
    abandoned=$(jq -r '.abandoned // false' "$result_file" 2>/dev/null || echo false)
  fi
  rm -f "$result_file"

  # The controller may have given up on this job (ctx timeout, restart)
  # while we were still running it. A successful create in that window
  # would otherwise leave an untracked microVM (names are unique per job
  # and never reused); destroy it ourselves.
  if [ "$status" -eq 0 ] && [ "$abandoned" = "true" ] && [ "${args[0]:-}" = "create" ]; then
    local vm_name="" prev=""
    for a in "${args[@]}"; do
      if [ "$prev" = "-n" ] || [ "$prev" = "--name" ]; then
        vm_name="$a"
        break
      fi
      prev="$a"
    done
    if [ -n "$vm_name" ]; then
      log "job ${id}: controller abandoned create of ${vm_name}; destroying leftover microVM"
      env "${env_assignments[@]}" "$bin" destroy "$vm_name" -f >/dev/null 2>&1 || log "job ${id}: leftover destroy of ${vm_name} failed"
    fi
  fi
}

# job_vm_name prints the microVM a job acts on (`create -n NAME ...` or
# `destroy NAME ...`), or nothing for anything else.
job_vm_name() {
  jq -r '
    .args as $a
    | if $a[0] == "create" then
        (($a | index("-n")) // ($a | index("--name"))) as $i
        | if $i then $a[$i + 1] else "" end
      elif $a[0] == "destroy" then $a[1] // ""
      else "" end' <<<"$1"
}

# Jobs run in the background, up to MAX_PARALLEL_JOBS at once, so one
# onctl create no longer holds up every other create and destroy for this
# host: a workflow that fans out to several jobs used to bring its runners
# online one after another, each waiting out the creates ahead of it. The
# controller already queues and tracks jobs per id, and onctl takes its own
# locks around IP allocation, so nothing else needs to change for that.
#
# What the old one-at-a-time loop gave for free was ordering, and that is
# kept per microVM: a job is started only after the previous job for the
# same VM name has exited. Otherwise the destroy the controller sends after
# giving up on a slow create could finish first, find nothing, and leave
# the create to produce a microVM nobody tracks.
#
# A background job outlives this process: systemd stops only the agent's
# own PID (KillMode=process in the unit), so on a restart the jobs already
# running finish and report on their own.
declare -a job_pids=()
declare -A vm_last_pid=()

# reap_jobs drops finished jobs from job_pids / vm_last_pid.
reap_jobs() {
  local -a alive=()
  local pid name
  for pid in "${job_pids[@]:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive+=("$pid"); fi
  done
  job_pids=("${alive[@]:-}")
  for name in "${!vm_last_pid[@]}"; do
    kill -0 "${vm_last_pid[$name]}" 2>/dev/null || unset "vm_last_pid[$name]"
  done
}

running_jobs() {
  local n=0 pid
  for pid in "${job_pids[@]:-}"; do
    [ -n "$pid" ] && n=$((n + 1))
  done
  echo "$n"
}

log "polling for work (up to ${MAX_PARALLEL_JOBS} jobs at once)"
while true; do
  # Don't claim a job there is no slot for: an unclaimed job stays in the
  # controller's queue, where a cancelled create is still skipped.
  reap_jobs
  while [ "$(running_jobs)" -ge "$MAX_PARALLEL_JOBS" ]; do
    wait -n 2>/dev/null || true
    reap_jobs
  done

  if ! resp=$(agent_curl -sS -m 40 -w '\n%{http_code}' \
    "${CONTROLLER_URL}/hosts/${HOST_NAME}/jobs/next"); then
    log "jobs/next request failed, retrying in 5s"
    sleep 5
    continue
  fi
  http_code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http_code" in
  200)
    vm_name=$(job_vm_name "$body" 2>/dev/null || true)
    after_pid=""
    if [ -n "$vm_name" ]; then after_pid="${vm_last_pid[$vm_name]:-}"; fi
    run_job "$body" "$after_pid" &
    job_pids+=("$!")
    if [ -n "$vm_name" ]; then vm_last_pid[$vm_name]=$!; fi
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
