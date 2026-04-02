#!/usr/bin/env bash

# wget -qO- "https://raw.githubusercontent.com/xxx/main/start-server.sh" | bash

set -Eeuo pipefail

MODEL_SERVER_URL="${MODEL_SERVER_URL:-http://127.0.0.1}"
MODEL_SERVER_PORT="${MODEL_SERVER_PORT:-18000}"
MODEL_LOG_FILE="${MODEL_LOG_FILE:-/var/log/model/server.log}"
WORKER_ENTRYPOINT="${WORKER_ENTRYPOINT:-worker.py}"
MODEL_ENTRYPOINT="${MODEL_ENTRYPOINT:-mock_model_server.py}"
HEALTH_PATH="${MODEL_HEALTH_PATH:-/health}"
HEALTH_TIMEOUT_SECONDS="${MODEL_HEALTH_TIMEOUT_SECONDS:-90}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
SERVER_DIR="${SERVER_DIR:-$WORKSPACE_DIR/pyworker-src}"
PYWORKER_REPO="${PYWORKER_REPO:-https://github.com/xxx.git}"
PYWORKER_REF="${PYWORKER_REF:-main}"
AUTO_INSTALL_REQUIREMENTS="${AUTO_INSTALL_REQUIREMENTS:-true}"

MODEL_PID=""
WORKER_PID=""

mkdir -p "$(dirname "$MODEL_LOG_FILE")"
touch "$MODEL_LOG_FILE"

ensure_repo_checkout() {
  if [[ -f "$WORKER_ENTRYPOINT" && -f "$MODEL_ENTRYPOINT" ]]; then
    return 0
  fi

  if [[ -z "$PYWORKER_REPO" ]]; then
    echo "[start-server] missing local files and PYWORKER_REPO is not set"
    echo "[start-server] set PYWORKER_REPO to a git URL containing $WORKER_ENTRYPOINT and $MODEL_ENTRYPOINT"
    exit 1
  fi

  mkdir -p "$WORKSPACE_DIR"

  if [[ ! -d "$SERVER_DIR/.git" ]]; then
    echo "[start-server] cloning repo: $PYWORKER_REPO -> $SERVER_DIR"
    git clone "$PYWORKER_REPO" "$SERVER_DIR"
  else
    echo "[start-server] updating repo in $SERVER_DIR"
    git -C "$SERVER_DIR" fetch --all --tags
    git -C "$SERVER_DIR" pull --ff-only
  fi

  if [[ -n "$PYWORKER_REF" ]]; then
    echo "[start-server] checking out ref: $PYWORKER_REF"
    git -C "$SERVER_DIR" checkout "$PYWORKER_REF"
  fi

  cd "$SERVER_DIR"

  if [[ "$AUTO_INSTALL_REQUIREMENTS" == "true" && -f "requirements.txt" ]]; then
    echo "[start-server] installing Python requirements"
    "$PYTHON_BIN" -m pip install -r requirements.txt
  fi

  if [[ ! -f "$WORKER_ENTRYPOINT" ]]; then
    echo "[start-server] worker entrypoint not found: $WORKER_ENTRYPOINT"
    exit 1
  fi

  if [[ ! -f "$MODEL_ENTRYPOINT" ]]; then
    echo "[start-server] model entrypoint not found: $MODEL_ENTRYPOINT"
    exit 1
  fi
}

shutdown() {
  local sig="${1:-TERM}"

  if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    kill "-$sig" "$WORKER_PID" 2>/dev/null || true
  fi

  if [[ -n "$MODEL_PID" ]] && kill -0 "$MODEL_PID" 2>/dev/null; then
    kill "-$sig" "$MODEL_PID" 2>/dev/null || true
  fi

  wait || true
}

on_term() {
  echo "[start-server] received termination signal, stopping child processes"
  shutdown TERM
  exit 0
}

on_exit() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    echo "[start-server] exiting with error code $code"
  fi
  shutdown TERM
}

trap on_term INT TERM
trap on_exit EXIT

ensure_repo_checkout

echo "[start-server] starting model backend: $MODEL_ENTRYPOINT"
"$PYTHON_BIN" "$MODEL_ENTRYPOINT" >>"$MODEL_LOG_FILE" 2>&1 &
MODEL_PID=$!

HEALTH_URL="${MODEL_SERVER_URL}:${MODEL_SERVER_PORT}${HEALTH_PATH}"
echo "[start-server] waiting for model health: $HEALTH_URL"

start_time=$(date +%s)
while true; do
  if curl --silent --show-error --fail "$HEALTH_URL" >/dev/null; then
    echo "[start-server] model backend is healthy"
    break
  fi

  if ! kill -0 "$MODEL_PID" 2>/dev/null; then
    echo "[start-server] model backend exited before becoming healthy"
    exit 1
  fi

  now=$(date +%s)
  elapsed=$((now - start_time))
  if (( elapsed >= HEALTH_TIMEOUT_SECONDS )); then
    echo "[start-server] model health check timed out after ${HEALTH_TIMEOUT_SECONDS}s"
    exit 1
  fi

  sleep 1
done

echo "[start-server] starting worker: $WORKER_ENTRYPOINT"
"$PYTHON_BIN" "$WORKER_ENTRYPOINT" &
WORKER_PID=$!

wait -n "$WORKER_PID" "$MODEL_PID"
exit_code=$?

if ! kill -0 "$WORKER_PID" 2>/dev/null; then
  echo "[start-server] worker exited unexpectedly"
else
  echo "[start-server] model backend exited unexpectedly"
fi

exit "$exit_code"
