#!/usr/bin/env bash
set -euo pipefail

# The tunnels fleet gave this mini, each a cloudflared, as the tunnels
# workload, which its supervisor runs. fleet also runs it to hand a shared
# tunnel over from one server to another in about a second:
#
#   tunnels.sh reload          have the running tunnels take the token file as
#                              it is now, those it keeps staying connected, and
#                              wait until those it dropped have stopped, after
#                              their last requests
#   tunnels.sh reload --wait   the same, then wait until each is connected

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SERVER_DIR/.tokens"
RUNNING_DIR="$HOME/.config/dots/running"
# The running tunnels.sh, which takes a reload, as one from before could not.
PID_FILE="$RUNNING_DIR/tunnels.pid"
NAMES=()
TOKENS=()
PIDS=()

# The tunnels fleet gave this mini, one NAME TOKEN per line.
read_tokens() {
    NAMES=()
    TOKENS=()
    [ -r "$TOKEN_FILE" ] || return 0
    while IFS=$' \t\r' read -r name token || [ -n "$name" ]; do
        case "$name" in
            ''|\#*) continue ;;
        esac
        NAMES+=("$name")
        TOKENS+=("$token")
    done < "$TOKEN_FILE"
}

# The cloudflared processes of the running tunnels.sh, one per tunnel, and
# for a while one it dropped, until its last requests end.
tunnel_pids() {
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -z "$pid" ] || pgrep -P "$pid" -x cloudflared || true
}

# How many of them Cloudflare has connected.
connected_count() {
    local pid port count=0
    for pid in $(tunnel_pids); do
        port="$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*://p' | head -1)"
        if [ -n "$port" ] && curl -s -m 1 "http://127.0.0.1:$port/ready" | jq -e '.readyConnections > 0' >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

case "$#:${1:-}:${2:-}" in
    0::) ;;
    1:reload: | 2:reload:--wait)
        read_tokens
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
            [[ "$(ps -ww -p "$pid" -o command=)" == *server/tunnels.sh ]]; then
            kill -USR1 "$pid"
        else
            # Tunnels from before a reload was possible, or none: restarted.
            "$SERVER_DIR/workloads.sh" stop tunnels
            "$SERVER_DIR/workloads.sh" start
        fi
        # Checked every tenth of a second, as fleet acts on it at once.
        for _ in {1..1200}; do
            if [ "${2:-}" = --wait ]; then
                [ "$(connected_count)" -lt "${#TOKENS[@]}" ] || exit 0
            else
                [ "$(tunnel_pids | wc -l | tr -d ' ')" -gt "${#TOKENS[@]}" ] || exit 0
            fi
            sleep 0.1
        done
        echo "The tunnels did not take the token file within 2 minutes." >&2
        exit 1
        ;;
    *)
        echo "Usage: $0 [reload [--wait]]" >&2
        exit 1
        ;;
esac

backends_running() {
    pgrep -x bitcoind >/dev/null &&
        pgrep -x bitviewd >/dev/null &&
        pgrep -x bitview_mcp >/dev/null
}

command -v cloudflared >/dev/null || {
    echo "cloudflared is not installed; run ./server/setup.sh first." >&2
    exit 1
}

read_tokens
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
    rm -f "$PID_FILE"
    stop_tunnels
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# A reload, which tunnels.sh reload asks for, taken at the next check.
reload=''
trap 'reload=1' USR1
mkdir -p "$RUNNING_DIR"
echo "$$" > "$PID_FILE"

# This mini's own tunnel, the one named after it on the tailnet, as fleet
# names it: its index in NAMES, if it has one.
self="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName | split(".")[0]' 2>/dev/null || true)"
find_own() {
    local index
    OWN=''
    for index in "${!NAMES[@]}"; do
        [ "${NAMES[$index]}" != "$self" ] || OWN="$index"
    done
}
find_own

# Take the token file as it is now: start the tunnels it gained, stop those it
# dropped, and leave connected those it kept, so handing a tunnel over moves
# it alone. One kept but stopped, as the own tunnel while Bitview is behind,
# stays so. The tokens it runs on are recorded, as the supervisor does.
apply_tokens() {
    local old_names=() old_tokens=() old_pids=() i j kept
    for i in "${!NAMES[@]}"; do
        old_names[$i]="${NAMES[$i]}"
        old_tokens[$i]="${TOKENS[$i]}"
        old_pids[$i]="${PIDS[$i]:-}"
    done
    read_tokens
    PIDS=()
    for j in "${!NAMES[@]}"; do
        kept=''
        for i in "${!old_names[@]}"; do
            if [ "${old_names[$i]}" = "${NAMES[$j]}" ] && [ "${old_tokens[$i]}" = "${TOKENS[$j]}" ]; then
                kept=1
                [ -z "${old_pids[$i]}" ] || PIDS[$j]="${old_pids[$i]}"
                old_pids[$i]=''
                break
            fi
        done
        [ -n "$kept" ] || start_tunnel "$j"
    done
    for i in "${!old_pids[@]}"; do
        if [ -n "${old_pids[$i]}" ]; then
            echo "Leaving tunnel ${old_names[$i]}..."
            kill "${old_pids[$i]}" 2>/dev/null || true
        fi
    done
    find_own
    shasum "$TOKEN_FILE" 2>/dev/null | cut -d ' ' -f 1 > "$RUNNING_DIR/tunnels"
}

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
    # A reload asked while the tunnels were down: the token file as it is now.
    if [ -n "$reload" ]; then
        reload=''
        read_tokens
        find_own
        shasum "$TOKEN_FILE" 2>/dev/null | cut -d ' ' -f 1 > "$RUNNING_DIR/tunnels"
    fi
    for index in "${!TOKENS[@]}"; do
        start_tunnel "$index"
    done
    behind_since=''
    checked=$SECONDS
    while backends_running; do
        if [ -n "$reload" ]; then
            reload=''
            apply_tokens
        fi
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
        # A reload interrupts the wait, so it is taken at once.
        sleep 1 &
        wait $! || true
    done
    echo "bitcoind, bitviewd, or bitview_mcp is down; the tunnels wait for it." >&2
    stop_tunnels
done
