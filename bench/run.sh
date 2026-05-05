#!/usr/bin/env bash
# Pika v0.6 benchmark harness
# Usage: ./bench/run.sh
# Requires: bombardier (brew install bombardier), crystal

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BENCH_DIR/.." && pwd)"
BIN="$BENCH_DIR/server"
MT_BIN="$BENCH_DIR/server_mt"

DURATION=15s
CONCURRENCY=128
PORT=3000
WORKERS=4

STATIC_URL="http://localhost:$PORT/bench/static"
JSON_URL="http://localhost:$PORT/bench/json"
VALIDATED_URL="http://localhost:$PORT/bench"
VALIDATED_BODY='{"name":"alice","count":42}'

# ---------------------------------------------------------------------------
bomb_get()  { bombardier -c "$CONCURRENCY" -d "$DURATION" "$1"; }
bomb_post() { bombardier -c "$CONCURRENCY" -d "$DURATION" -m POST \
                -H "Content-Type: application/json" -b "$2" "$1"; }

wait_ready() {
  local url="$1"
  for i in $(seq 1 30); do
    curl -sf "$url" > /dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "Server did not become ready at $url" >&2; exit 1
}

kill_port() { lsof -ti tcp:"$PORT" | xargs kill -9 2>/dev/null || true; }

# ---------------------------------------------------------------------------
echo "=== Building single-threaded binary ==="
cd "$ROOT"
crystal build bench/server.cr -o "$BIN" --release

echo ""
echo "=== Building multi-threaded binary (preview_mt) ==="
crystal build bench/server.cr -o "$MT_BIN" --release -Dpreview_mt

# ---------------------------------------------------------------------------
run_mode() {
  local label="$1"
  local bin="$2"
  shift 2
  local env_prefix=("$@")

  echo ""
  echo "=============================="
  echo "  $label"
  echo "=============================="

  kill_port

  if [ "$label" = "4× reuse_port (multi-process)" ]; then
    # spawn WORKERS processes, each with REUSE_PORT=1
    for i in $(seq 1 $WORKERS); do
      PORT=$PORT REUSE_PORT=1 "$bin" &
    done
  else
    env "${env_prefix[@]}" PORT=$PORT "$bin" &
  fi

  SERVER_PID=$!
  wait_ready "$STATIC_URL"

  echo "--- Static route (GET /bench/static) ---"
  bomb_get "$STATIC_URL"

  echo "--- JSON response (GET /bench/json) ---"
  bomb_get "$JSON_URL"

  echo "--- Validated params (POST /bench) ---"
  bomb_post "$VALIDATED_URL" "$VALIDATED_BODY"

  kill_port
  sleep 0.5
}

run_mode "Single-threaded"           "$BIN"    "CRYSTAL_WORKERS=1"
run_mode "--threads 4 (preview_mt)"  "$MT_BIN" "CRYSTAL_WORKERS=$WORKERS"
run_mode "4× reuse_port (multi-process)" "$BIN" ""

echo ""
echo "=== Done ==="
