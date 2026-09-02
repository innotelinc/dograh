#!/usr/bin/env bash
set -e

###############################################################################
### CONFIGURATION
###############################################################################

BASE_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="$BASE_DIR/api/.env"

ARQ_WORKERS=${ARQ_WORKERS:-1}
FASTAPI_WORKERS=${FASTAPI_WORKERS:-1}
UVICORN_BASE_PORT=${UVICORN_BASE_PORT:-8000}

# Process supervision. Every child (arq / ari_manager /
# campaign_orchestrator / uvicorn) is restarted on crash so a single failure
# — e.g. the PBX ARI endpoint briefly refusing connections, or one uvicorn
# worker dying — doesn't tear down the whole container and every in-flight
# call with it. Only a worker crashing more than MAX_CONSECUTIVE_RESTARTS
# times in a row tears the container down so docker/systemd restarts it
# cleanly.
MAX_CONSECUTIVE_RESTARTS=${MAX_CONSECUTIVE_RESTARTS:-5}
RESTART_BACKOFF_SECONDS=${RESTART_BACKOFF_SECONDS:-2}
RESTART_COUNTER_RESET_UPTIME_SECONDS=${RESTART_COUNTER_RESET_UPTIME_SECONDS:-300}

cd "$BASE_DIR"
echo "Starting Dograh Services (DOCKER) at $(date) in BASE_DIR: ${BASE_DIR}"

###############################################################################
### 1) Load env file if mounted (env normally comes from docker-compose)
###############################################################################

if [[ -f "$ENV_FILE" ]]; then
  set -a && . "$ENV_FILE" && set +a
fi

###############################################################################
### 2) Run migrations
###############################################################################

alembic -c "$BASE_DIR/api/alembic.ini" upgrade head

###############################################################################
### 3) Signal handling — forward TERM/INT to children for clean docker stop
###############################################################################

declare -A CHILD_PIDS=()      # name -> live PID
declare -A CHILD_CMDS=()      # name -> command line (re-invoked on restart)
declare -A CHILD_RESTARTS=()  # name -> consecutive crash count
declare -A CHILD_STARTED_AT=()  # name -> epoch seconds of last start

shutdown() {
  echo "Received shutdown signal, stopping services..."
  for name in "${!CHILD_PIDS[@]}"; do
    kill -TERM "${CHILD_PIDS[$name]}" 2>/dev/null || true
  done
  wait
  exit 0
}

trap shutdown TERM INT

relaunch() {
  local name=$1
  echo "→ Starting $name"
  # Commands are hardcoded at the call sites below (never user input), so
  # eval is safe. `exec` makes the background subshell *become* the command,
  # so $! is the real process PID and a later TERM reaches it directly.
  eval "exec ${CHILD_CMDS[$name]}" &
  CHILD_PIDS[$name]=$!
  CHILD_STARTED_AT[$name]=$(date +%s)
  echo "  $name PID ${CHILD_PIDS[$name]}"
}

start() {
  local name=$1
  shift
  # Shell-escape each argument so `eval` in relaunch() reconstructs the exact
  # command (argument boundaries, embedded quotes, etc.) regardless of content.
  local quoted=""
  printf -v quoted '%q ' "$@"
  CHILD_CMDS[$name]=$quoted
  relaunch "$name"
}

###############################################################################
### 4) Start services (logs go to stdout for `docker logs`)
###############################################################################

# ari_manager and campaign_orchestrator are optional; each defaults to on and
# can be turned off (e.g. for an API/worker-only replica) by setting the flag to
# "false" in the container env / docker-compose .env.
ENABLE_ARI_MANAGER=${ENABLE_ARI_MANAGER:-true}
ENABLE_CAMPAIGN_ORCHESTRATOR=${ENABLE_CAMPAIGN_ORCHESTRATOR:-true}

if [[ "$ENABLE_ARI_MANAGER" == "true" ]]; then
  start ari_manager           python -m api.services.telephony.ari_manager
else
  echo "ari_manager disabled (ENABLE_ARI_MANAGER=$ENABLE_ARI_MANAGER)"
fi

if [[ "$ENABLE_CAMPAIGN_ORCHESTRATOR" == "true" ]]; then
  start campaign_orchestrator python -m api.services.campaign.campaign_orchestrator
else
  echo "campaign_orchestrator disabled (ENABLE_CAMPAIGN_ORCHESTRATOR=$ENABLE_CAMPAIGN_ORCHESTRATOR)"
fi

# Spawn FASTAPI_WORKERS independent uvicorn processes on consecutive ports
# starting at UVICORN_BASE_PORT. nginx upstream (configured in setup_remote.sh)
# balances across them with least_conn — better than uvicorn --workers for
# long-lived WebSocket connections, which would otherwise stick to whichever
# worker accepted them first.
for ((i=0; i<FASTAPI_WORKERS; i++)); do
  port=$((UVICORN_BASE_PORT + i))
  start "uvicorn$i" uvicorn api.app:app --host 0.0.0.0 --port "$port" --workers 1
done

for ((i=1; i<=ARQ_WORKERS; i++)); do
  start "arq$i" python -m arq api.tasks.arq.WorkerSettings --custom-log-dict api.tasks.arq.LOG_CONFIG
done

###############################################################################
### 5) Supervise the process tree
###############################################################################

supervise() {
  while ((${#CHILD_PIDS[@]} > 0)); do
    # `wait -n` returns the exited child's status; disable `set -e` so a
    # non-zero status doesn't abort the script.
    set +e
    wait -n
    local status=$?
    set -e

    # Identify the child that exited by locating a recorded PID that is gone.
    local exited_name=""
    for name in "${!CHILD_PIDS[@]}"; do
      if ! kill -0 "${CHILD_PIDS[$name]}" 2>/dev/null; then
        exited_name=$name
        break
      fi
    done

    if [[ -z "$exited_name" ]]; then
      # No tracked child exited (e.g. a signal woke `wait`); keep supervising.
      continue
    fi

    unset 'CHILD_PIDS[$exited_name]'

    # A worker that survived long enough is considered healthy — reset its
    # consecutive-crash counter so only a tight crash loop escalates.
    local now
    now=$(date +%s)
    if (( now - ${CHILD_STARTED_AT[$exited_name]:-0} >= RESTART_COUNTER_RESET_UPTIME_SECONDS )); then
      CHILD_RESTARTS[$exited_name]=0
    fi
    CHILD_RESTARTS[$exited_name]=$(( ${CHILD_RESTARTS[$exited_name]:-0} + 1 ))

    if (( ${CHILD_RESTARTS[$exited_name]} > MAX_CONSECUTIVE_RESTARTS )); then
      echo "Worker '$exited_name' crashed ${CHILD_RESTARTS[$exited_name]} times consecutively; tearing down container."
      shutdown
    fi

    echo "Worker '$exited_name' exited (status $status); restarting in ${RESTART_BACKOFF_SECONDS}s (attempt ${CHILD_RESTARTS[$exited_name]}/${MAX_CONSECUTIVE_RESTARTS})."
    sleep "$RESTART_BACKOFF_SECONDS"
    relaunch "$exited_name"
  done
}

supervise
