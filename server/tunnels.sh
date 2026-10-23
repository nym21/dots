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

# The tunnels fleet gave this mini, one NAME TOKEN per line.
if [ -r "$TOKEN_FILE" ]; then
    while IFS=$' \t\r' read -r name token || [ -n "$name" ]; do
        case "$name" in
            ''|\#*) continue ;;
        esac
        NAMES+=("$name")
        TOKENS+=("$token")
    done < "$TOKEN_FILE"
fi

if [ "${#TOKENS[@]}" -eq 0 ]; then
    echo "No tunnel runs on this mini."
    exit 0
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
# Checked every second, so a restart is over as soon as Bitview serves.
wait_ready() {
    if ! ready; then
        echo "Waiting for Bitview to reach the tip and both servers to answer..."
        until ready; do
            sleep 1
        done
    fi
}

# Start the tunnel at INDEX in NAMES and TOKENS, or stop it.
start_tunnel() {
    echo "Starting tunnel ${NAMES[$1]}..."
    cloudflared tunnel run --token-file <(printf '%s' "${TOKENS[$1]}") &
    PIDS[$1]=$!
}
stop_tunnel() {
    kill "${PIDS[$1]}" 2>/dev/null || true
    wait "${PIDS[$1]}" 2>/dev/null || true
    unset "PIDS[$1]"
}

stop_tunnels() {
    if [ "${#PIDS[@]}" -gt 0 ]; then
        kill "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi
    PIDS=()
}

cleanup() {
    trap - EXIT HUP INT TERM
    stop_tunnels
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# This mini's own tunnel, the one named after it on the tailnet, as fleet
# names it: its index in NAMES, if it has one.
self="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName | split(".")[0]' 2>/dev/null || true)"
OWN=''
for index in "${!NAMES[@]}"; do
    [ "${NAMES[$index]}" != "$self" ] || OWN="$index"
done

# How long Bitview may stay behind the tip, in seconds, checked every minute,
# before this mini's own tunnel goes down.
STUCK_AFTER=600
CHECK_EVERY=60

# Serve while the other workloads run. While one is down, the tunnels are
# down too, so the other servers serve, and they come back once it serves
# again. Bitview stuck behind the tip would serve on what it has: then only
# this mini's own tunnel goes down, so Cloudflare's alert names it, while the
# shared ones serve on, as the other servers may be stuck as well; it comes
# back once Bitview reaches the tip. A tunnel that exits ends them all, for
# the supervisor to log and start again.
while true; do
    wait_ready
    for index in "${!TOKENS[@]}"; do
        start_tunnel "$index"
    done
    behind_since=''
    checked=$SECONDS
    while backends_running; do
        if [ "${#PIDS[@]}" -gt 0 ]; then
            for index in "${!PIDS[@]}"; do
                pid="${PIDS[$index]}"
                if ! kill -0 "$pid" 2>/dev/null; then
                    echo "Tunnel ${NAMES[$index]} exited; stopping this session's tunnels." >&2
                    unset "PIDS[$index]"
                    wait "$pid"
                    exit 1
                fi
            done
        fi
        if [ -n "$OWN" ] && [ $((SECONDS - checked)) -ge "$CHECK_EVERY" ]; then
            checked=$SECONDS
            if at_tip; then
                behind_since=''
                if [ -z "${PIDS[$OWN]:-}" ]; then
                    echo "Bitview is at the tip again; tunnel ${NAMES[$OWN]} serves again."
                    start_tunnel "$OWN"
                fi
            elif [ -z "$behind_since" ]; then
                behind_since=$SECONDS
            elif [ $((SECONDS - behind_since)) -ge "$STUCK_AFTER" ] && [ -n "${PIDS[$OWN]:-}" ]; then
                echo "Bitview has been behind the tip for $((STUCK_AFTER / 60)) minutes; tunnel ${NAMES[$OWN]} waits for it." >&2
                stop_tunnel "$OWN"
            fi
        fi
        sleep 1
    done
    echo "bitcoind, bitviewd, or bitview_mcp is down; the tunnels wait for it." >&2
    stop_tunnels
done
