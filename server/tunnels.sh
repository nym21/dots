#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
TUNNELS=(shared node mcp)
PIDS=()

backends_running() {
    pgrep -x bitcoind >/dev/null && pgrep -x bitviewd >/dev/null
}

command -v cloudflared >/dev/null || {
    echo "cloudflared is not installed; run ./server/import.sh first." >&2
    exit 1
}

# Validate all tokens before starting any tunnel. Their contents stay private.
for tunnel in "${TUNNELS[@]}"; do
    token_file="$SERVER_DIR/$tunnel.token"
    if [ ! -r "$token_file" ] || [ ! -s "$token_file" ]; then
        echo "Missing or empty token file: $token_file" >&2
        exit 1
    fi
done

if ! backends_running; then
    echo "Start bitcoind and bitviewd before starting the tunnels." >&2
    exit 1
fi

cleanup() {
    trap - EXIT HUP INT TERM
    if [ "${#PIDS[@]}" -gt 0 ]; then
        kill "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for tunnel in "${TUNNELS[@]}"; do
    echo "Starting $tunnel tunnel..."
    cloudflared tunnel run --token-file "$SERVER_DIR/$tunnel.token" &
    PIDS+=("$!")
done

while true; do
    if ! backends_running; then
        echo "bitcoind or bitviewd is down; stopping this session's tunnels." >&2
        exit 1
    fi
    for index in "${!PIDS[@]}"; do
        pid="${PIDS[$index]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "${TUNNELS[$index]} tunnel exited; stopping this session's tunnels." >&2
            unset 'PIDS[index]'
            wait "$pid"
            exit 1
        fi
    done
    sleep 1
done
