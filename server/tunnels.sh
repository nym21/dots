#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SERVER_DIR/tunnels.tokens"
TOKENS=()
PIDS=()

backends_running() {
    pgrep -x bitcoind >/dev/null && pgrep -x bitviewd >/dev/null
}

command -v cloudflared >/dev/null || {
    echo "cloudflared is not installed; run ./server/setup.sh first." >&2
    exit 1
}

if [ ! -r "$TOKEN_FILE" ]; then
    echo "Missing or unreadable token file: $TOKEN_FILE" >&2
    exit 1
fi

while IFS=$' \t\r' read -r token || [ -n "$token" ]; do
    case "$token" in
        ''|\#*) continue ;;
    esac
    TOKENS+=("$token")
done < "$TOKEN_FILE"

if [ "${#TOKENS[@]}" -eq 0 ]; then
    echo "No tokens found in $TOKEN_FILE" >&2
    exit 1
fi

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

for index in "${!TOKENS[@]}"; do
    echo "Starting tunnel $((index + 1))..."
    cloudflared tunnel run --token-file <(printf '%s' "${TOKENS[$index]}") &
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
            echo "Tunnel $((index + 1)) exited; stopping this session's tunnels." >&2
            unset 'PIDS[index]'
            wait "$pid"
            exit 1
        fi
    done
    sleep 1
done
