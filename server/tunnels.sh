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

# This mini's mode follows how bitviewd was installed: prod from crates.io,
# the branch name from a branch of the official repository, local from a
# checkout.
mode="$(cargo install --list | awk '
    $1 == "bitviewd" {
        if (NF == 2) print "prod"
        else if ($3 ~ /^\(\//) print "local"
        else if ($3 ~ /[?&]branch=/) {
            sub(/.*[?&]branch=/, "", $3)
            sub(/[#&)].*/, "", $3)
            print $3
        }
        exit
    }')"
if [ -z "$mode" ]; then
    echo "bitviewd is not installed with cargo; run ./server/bitview.sh first." >&2
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
    # Stay up, so launchd does not restart this every 10 seconds.
    echo "No tunnel runs on $host ($mode)."
    exec sleep 2147483647
fi

if ! backends_running; then
    echo "Start bitcoind, bitviewd, and bitview_mcp before starting the tunnels." >&2
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
