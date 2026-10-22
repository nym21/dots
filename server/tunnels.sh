#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SERVER_DIR/.tokens"
NAMES=()
TOKENS=()
PIDS=()

backends_running() {
    pgrep -x bitcoind >/dev/null &&
        pgrep -x bitviewd >/dev/null &&
        pgrep -x bitview_mcp >/dev/null
}

command -v cloudflared >/dev/null || {
    echo "cloudflared is not installed; run ./server/setup.sh first." >&2
    exit 1
}

if [ ! -r "$TOKEN_FILE" ]; then
    echo "Missing or unreadable token file: $TOKEN_FILE" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"
mode="$(bitview_mode)"
if [ -z "$mode" ]; then
    echo "bitviewd is not installed with cargo; run dots install first." >&2
    exit 1
fi

if ! host="$(tailscale status --json 2>/dev/null | jq -er '.Self.DNSName | split(".")[0]')"; then
    echo "Cannot read this mini's Tailscale name." >&2
    exit 1
fi

# Each line is NAME RUNS-ON... TOKEN. Start the tunnels whose RUNS-ON includes
# this mini's mode or its Tailscale name.
line_number=0
while IFS=$' \t\r' read -r -a fields || [ "${#fields[@]}" -gt 0 ]; do
    line_number=$((line_number + 1))
    [ "${#fields[@]}" -gt 0 ] || continue
    case "${fields[0]}" in
        \#*) continue ;;
    esac
    if [ "${#fields[@]}" -lt 3 ]; then
        echo "$TOKEN_FILE:$line_number: expected NAME RUNS-ON... TOKEN" >&2
        exit 1
    fi
    for runs_on in "${fields[@]:1:${#fields[@]}-2}"; do
        if [ "$runs_on" = "$mode" ] || [ "$runs_on" = "$host" ]; then
            NAMES+=("${fields[0]}")
            TOKENS+=("${fields[${#fields[@]}-1]}")
            break
        fi
    done
done < "$TOKEN_FILE"

if [ "${#TOKENS[@]}" -eq 0 ]; then
    echo "No tunnel runs on $host ($mode)."
    exit 0
fi

if ! backends_running; then
    echo "Start bitcoind, bitviewd, and bitview_mcp before starting the tunnels." >&2
    exit 1
fi

# The tunnels send public traffic here as soon as they connect, so wait until
# both servers answer, on the ports the tunnels route to, and Bitview has
# reached Bitcoin Core's tip.
at_tip() {
    local response body
    response="$(curl -s -m 5 -w '\n%{http_code}' http://127.0.0.1:3110/api/server/sync)" || return 1
    body="${response%$'\n'*}"
    case "${response##*$'\n'}" in
        2*)
            # The API differs between versions; one without the sync status
            # counts as at the tip.
            if jq -e 'type == "object" and has("blocks_behind")' >/dev/null 2>&1 <<< "$body"; then
                jq -e '.blocks_behind == 0' >/dev/null <<< "$body"
            fi
            ;;
        404) ;;
        *) return 1 ;;
    esac
}
ready() {
    curl -sf -m 5 -o /dev/null http://127.0.0.1:3110/ &&
        curl -sf -m 5 -o /dev/null http://127.0.0.1:3111/ &&
        at_tip
}
if ! ready; then
    echo "Waiting for Bitview to reach the tip and both servers to answer..."
    until ready; do
        if ! backends_running; then
            echo "bitcoind, bitviewd, or bitview_mcp is down; not starting the tunnels." >&2
            exit 1
        fi
        sleep 10
    done
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
    echo "Starting tunnel ${NAMES[$index]} on $host ($mode)..."
    cloudflared tunnel run --token-file <(printf '%s' "${TOKENS[$index]}") &
    PIDS+=("$!")
done

while true; do
    if ! backends_running; then
        echo "bitcoind, bitviewd, or bitview_mcp is down; stopping this session's tunnels." >&2
        exit 1
    fi
    for index in "${!PIDS[@]}"; do
        pid="${PIDS[$index]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Tunnel ${NAMES[$index]} exited; stopping this session's tunnels." >&2
            unset 'PIDS[index]'
            wait "$pid"
            exit 1
        fi
    done
    sleep 1
done
