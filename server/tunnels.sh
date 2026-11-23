#!/usr/bin/env bash
set -euo pipefail

# This mini's Cloudflare tunnels, those fleet gave it in server/.tokens, one
# cloudflared each, as the tunnels workload, which its supervisor runs. They
# serve while Bitcoin Core, Bitview and the MCP server run, starting once
# Bitview has reached Bitcoin Core's tip. The workload takes the token file
# when set writes it: a tunnel gained starts, one dropped stops after its last
# requests, and the others stay connected. A cloudflared that exits starts
# again 10 seconds later, alone. It records each tunnel's state, and appends
# each change to ~/Library/Logs/dots/tunnels.log, cut to its last 10,000 lines
# (about 500 KB) as it starts: TIME MINI TUNNEL connected|lost, TUNNEL being *
# when the workload starts, as what this mini held before is unknown then,
# dated by the state the last run left, when it ended without stopping, as in
# a power loss. It looks each second while something changes (it waits for
# the servers, a tunnel it runs is not ready, or one drains or waits to start
# again), each minute once all is steady, and at once when woken or when a
# cloudflared ends.
#
#   tunnels.sh set NAME...   take NAME..., their tokens on input as NAME TOKEN
#                            lines, as this mini's tunnels, and return once the
#                            workload has taken them: they alone listed, even
#                            draining, and ready, or, while it waits for the
#                            servers, listed
#   tunnels.sh state         the tunnels the token file names, then, while the
#                            workload runs, whether it serves or waits for the
#                            servers, and each tunnel's state: ready (connected,
#                            both servers answering), lost, or draining, as
#                            the workload finds them when asked
#   tunnels.sh wake          have the workload look again at once, as when a
#                            server it routes to ended

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$SERVER_DIR/.tokens"
STATE_FILE="$HOME/.config/dots/running/tunnels"
# A line written here wakes the workload; the pipe keeps it until read, so
# none is lost while the workload is busy. In the user's temporary folder,
# outside the home folder: a recursive read there (grep -r ~/.config) would
# block on the pipe and swallow the wakes.
WAKE="$(getconf DARWIN_USER_TEMP_DIR)dots-tunnels.wake"
LOG="$HOME/Library/Logs/dots/tunnels.log"
# The workload, by its command line, which the verbs' lack.
WORKLOAD='server/tunnels\.sh$'
# TEMPORARY, for the rollout from dots main of 2026-11, delete once every mini
# runs this script (no ~/.config/dots/running/tunnels.pid on any): the
# workload from before it wrote its pid there, and in place of the state, the
# shasum of the token file it took. Until ship apply restarts it into this
# one, it counts as holding its token file's tunnels ready while it runs one
# connected cloudflared for each, and set has it take a new token file with
# its own reload (USR1).
OLD_PID_FILE="$HOME/.config/dots/running/tunnels.pid"

usage() {
    echo "Usage: $0 [set NAME... | state | wake]" >&2
    exit 1
}

# The workload's state, while it runs, as it last recorded it.
recorded() {
    [ -r "$STATE_FILE" ] && pgrep -qf "$WORKLOAD" && cat "$STATE_FILE"
}

# Wake the workload, if it runs. Opened for reading too, so it never blocks,
# even on the pipe of one killed before it could remove it.
wake() {
    [ ! -p "$WAKE" ] || printf '\n' 1<>"$WAKE"
}

# The workload's state now: woken, it looks again and records it, within 10
# seconds or not at all, as when it hangs. (A workload from before the pipe
# records each second.)
fresh_state() {
    local before
    pgrep -qf "$WORKLOAD" || return 1
    [ -p "$WAKE" ] || { recorded; return; }
    before="$(stat -f %Fm "$STATE_FILE" 2>/dev/null || true)"
    wake
    for _ in {1..100}; do
        [ "$(stat -f %Fm "$STATE_FILE" 2>/dev/null)" = "$before" ] || { recorded; return; }
        sleep 0.1
    done
    echo "$SERVER_DIR/tunnels.sh: the workload did not record its state within 10 seconds." >&2
    return 1
}

names() {
    awk '!/^#/ && NF { print $1 }' "$TOKEN_FILE" 2>/dev/null || true
}

# The metrics port cloudflared PID listens on, and whether the one at PORT is
# connected, as its /ready says.
port_of() {
    lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*://p' | head -1
}
connected_at() {
    [ -n "$1" ] && curl -s -m 1 "http://127.0.0.1:$1/ready" | grep -q '"readyConnections":[1-9]'
}

old_workload() {
    local pid
    pid="$(cat "$OLD_PID_FILE" 2>/dev/null)" && kill -0 "$pid" 2>/dev/null
}
old_running() {
    pgrep -P "$(cat "$OLD_PID_FILE")" -x cloudflared || true
}
old_connected() {
    local pid
    for pid in $(old_running); do
        connected_at "$(port_of "$pid")" || return 1
    done
}
old_ready() {
    [ "$(old_running | wc -l)" -eq "$(names | wc -l)" ] && old_connected
}

case "${1:-}" in
    '') ;;
    state)
        [ "$#" -eq 1 ] || usage
        echo "tokens $(names | xargs)"
        if old_workload; then # (TEMPORARY, with OLD_PID_FILE.)
            ! old_ready || names | sed 's/$/ ready/'
        else
            fresh_state || true
        fi
        exit 0
        ;;
    wake)
        [ "$#" -eq 1 ] || usage
        wake
        exit 0
        ;;
    set)
        shift
        # Only whole lines count, so a connection lost while they come in
        # leaves a tunnel without its token, and nothing is written.
        tokens=''
        while IFS=$' \t' read -r name token; do
            case " $* " in *" $name "*) tokens="$tokens$name $token"$'\n' ;; esac
        done
        for name; do
            grep -q "^$name " <<< "$tokens" || {
                echo "$SERVER_DIR/tunnels.sh: no token came for $name; nothing changed." >&2
                exit 1
            }
        done
        # Those it runs already need not be ready again, as its own tunnel
        # stopped while Bitview is behind.
        had=" $({ recorded || true; } | awk 'NF == 2 && $2 != "draining" { print $1 }' | xargs) "
        (umask 077 && printf '%s' "$tokens" > "$TOKEN_FILE.new" && mv "$TOKEN_FILE.new" "$TOKEN_FILE")
        # Not running, as while the mini is stopped or benching: it takes them
        # when it starts.
        pgrep -qf "$WORKLOAD" || exit 0
        wake
        if old_workload; then # (TEMPORARY, with OLD_PID_FILE.)
            sum="$(shasum "$TOKEN_FILE" | cut -d ' ' -f 1)"
            kill -USR1 "$(cat "$OLD_PID_FILE")"
        fi
        want="$(printf '%s\n' "$@" | sort -u | xargs)"
        # Whether the workload took the token file: the state lists just those
        # tunnels, the dropped done draining, and each gained ready, or none
        # as it waits for the mini's servers.
        taken() {
            local state name
            # (TEMPORARY, with OLD_PID_FILE: it recorded the file, the dropped
            # stopped, and the cloudflareds it runs are connected, or none
            # run, as it waits for the servers.)
            if old_workload; then
                [ -z "$(old_running)" ] || { [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$sum" ] &&
                    [ "$(old_running | wc -l)" -le "$(names | wc -l)" ] && old_connected; }
                return
            fi
            state="$(recorded)" || return 1
            [ "$(awk 'NF == 2 { print $1 }' <<< "$state" | sort -u | xargs)" = "$want" ] || return 1
            if grep -qx waiting <<< "$state"; then
                echo "$SERVER_DIR/tunnels.sh: the tunnels wait for this mini's servers; they serve once it does." >&2
                return 0
            fi
            for name in $want; do
                case "$had" in *" $name "*) ;; *) grep -qx "$name ready" <<< "$state" || return 1 ;; esac
            done
        }
        # Checked every tenth of a second, as fleet acts on it at once.
        for _ in {1..1200}; do
            ! taken || exit 0
            sleep 0.1
        done
        echo "$SERVER_DIR/tunnels.sh: the tunnels did not take $* within 2 minutes." >&2
        exit 1
        ;;
    *) usage ;;
esac

command -v cloudflared >/dev/null || {
    echo "cloudflared is not installed; run ./server/setup.sh first." >&2
    exit 1
}

backends_running() {
    pgrep -x bitcoind >/dev/null &&
        pgrep -x bitviewd >/dev/null &&
        pgrep -x bitview_mcp >/dev/null
}

# Whether both servers answer, on the ports the tunnels route to.
answering() {
    curl -sf -m 2 -o /dev/null http://127.0.0.1:3110/ &&
        curl -sf -m 2 -o /dev/null http://127.0.0.1:3111/
}

# The tunnels send public traffic here as soon as they connect, so they start
# only once both servers answer and Bitview has reached Bitcoin Core's tip.
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

NAMES=()
TOKENS=()
# Each tunnel's cloudflared, its metrics port once known, and when it exited.
PIDS=()
PORTS=()
EXITED=()
# Those dropped, until their last requests end.
DRAINING=()
DRAINING_NAMES=()

# Start the tunnel at INDEX in NAMES and TOKENS.
start_tunnel() {
    echo "Starting tunnel ${NAMES[$1]}..."
    # HTTP/2, not QUIC, cloudflared's default: Bitview's large uncompressed
    # responses reach the edge about 18% faster over it, and small ones no slower.
    cloudflared tunnel run --protocol http2 --token-file <(printf '%s' "${TOKENS[$1]}") 3<&- &
    PIDS[$1]=$!
    unset "PORTS[$1]" "EXITED[$1]"
}

# Stop the tunnel at INDEX, which drains until its last requests end.
stop_tunnel() {
    [ -n "${PIDS[$1]:-}" ] || return 0
    kill "${PIDS[$1]}" 2>/dev/null || true
    DRAINING+=("${PIDS[$1]}")
    DRAINING_NAMES+=("${NAMES[$1]}")
    unset "PIDS[$1]" "PORTS[$1]"
}

# Whether the tunnel at INDEX is connected, as its cloudflared's /ready says,
# on the metrics port it chose, looked up once.
tunnel_ready() {
    [ -n "${PIDS[$1]:-}" ] || return 1
    [ -n "${PORTS[$1]:-}" ] || PORTS[$1]="$(port_of "${PIDS[$1]}")"
    connected_at "${PORTS[$1]}"
}

# Take the token file's CONTENT: start the tunnels it gained while serving,
# stop those it dropped, and keep the others as they are. A tunnel keeps its
# index for as long as it runs, the others' left empty.
added=0
apply_tokens() {
    local index name token kept=' '
    while IFS=$' \t\r' read -r name token; do
        case "$name" in ''|\#*) continue ;; esac
        for index in "${!NAMES[@]}"; do
            if [ "${NAMES[$index]} ${TOKENS[$index]}" = "$name $token" ]; then
                kept="$kept$index "
                continue 2
            fi
        done
        added=$((added + 1))
        NAMES[added]="$name" TOKENS[added]="$token"
        kept="$kept$added "
        [ -z "$serving" ] || start_tunnel "$added"
    done <<< "$1"
    for index in "${!NAMES[@]}"; do
        case "$kept" in *" $index "*) continue ;; esac
        echo "Leaving tunnel ${NAMES[$index]}..."
        stop_tunnel "$index"
        unset "NAMES[$index]" "TOKENS[$index]" "EXITED[$index]"
    done
    find_own
}

# Write the state, which fleet and ship status read, and log each tunnel that
# became ready or stopped being so since the last. $steady says whether all
# is as it should stay: serving, each tunnel it runs ready, none draining or
# waiting to start again.
connected=' '
steady=''
record_state() {
    local index now=' ' name up=''
    steady="$serving"
    [ -z "$serving" ] || ! answering || up=1
    {
        if [ -n "$serving" ]; then echo serving; else echo waiting; fi
        for index in "${!NAMES[@]}"; do
            if [ -n "$up" ] && tunnel_ready "$index"; then
                echo "${NAMES[$index]} ready"
                now="$now${NAMES[$index]} "
            else
                echo "${NAMES[$index]} lost"
                # (Not one stopped while Bitview is behind, which stays so.)
                [ -z "${PIDS[$index]:-}${EXITED[$index]:-}" ] || steady=''
            fi
        done
        for index in "${!DRAINING[@]}"; do
            echo "${DRAINING_NAMES[$index]} draining"
            steady=''
        done
    } > "$STATE_FILE.new"
    mv "$STATE_FILE.new" "$STATE_FILE"
    for name in $now; do
        case "$connected" in *" $name "*) ;; *) log "$name" connected ;; esac
    done
    for name in $connected; do
        case "$now" in *" $name "*) ;; *) log "$name" lost ;; esac
    done
    connected="$now"
}

# Log TUNNEL's STATE, now, or at the epoch second WHEN.
log() {
    printf '%s %s %s %s\n' "$(date -u -r "${3:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)" "${self:-?}" "$1" "$2" >> "$LOG"
}

# Whether every tunnel's cloudflared still runs.
cloudflareds_run() {
    local index
    for index in "${!PIDS[@]}"; do
        kill -0 "${PIDS[$index]}" 2>/dev/null || return 1
    done
}

# Forget the drained tunnels whose cloudflared has ended.
reap() {
    local index
    for index in "${!DRAINING[@]}"; do
        if ! kill -0 "${DRAINING[$index]}" 2>/dev/null; then
            wait "${DRAINING[$index]}" 2>/dev/null || true
            unset "DRAINING[$index]" "DRAINING_NAMES[$index]"
        fi
    done
}

cleanup() {
    local index
    trap - EXIT HUP INT TERM
    # First, so state answers at once while the tunnels drain.
    rm -f "$STATE_FILE" "$WAKE"
    for name in $connected; do
        log "$name" lost
    done
    for index in "${!NAMES[@]}"; do
        stop_tunnel "$index"
    done
    for index in "${!DRAINING[@]}"; do
        while kill -0 "${DRAINING[$index]}" 2>/dev/null; do
            wait "${DRAINING[$index]}" 2>/dev/null || true
        done
    done
}

# This mini's own tunnel, the one named after it on the tailnet, as fleet
# names it: its index in NAMES, if it has one. tailscaled may not know the name
# yet, as at boot, so it is asked again until it does.
self=''
find_own() {
    local index
    [ -n "$self" ] || self="$(tailscale status --json 2>/dev/null |
        jq -r '.Self.DNSName // "" | split(".")[0] // empty' 2>/dev/null)" || self=''
    OWN=''
    [ -n "$self" ] || return 0
    for index in "${!NAMES[@]}"; do
        [ "${NAMES[$index]}" != "$self" ] || OWN="$index"
    done
}

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
# Made aside and moved in, as a wake meanwhile would make it a plain file.
mkfifo -m 600 "$WAKE.$$"
mv -f "$WAKE.$$" "$WAKE"
exec 3<>"$WAKE"
if [ -f "$LOG" ]; then
    tail -n 10000 "$LOG" > "$LOG.new" && mv "$LOG.new" "$LOG"
fi
# Only this workload runs cloudflared on a mini, so any running now was left by
# one killed before it could stop them, and serves what it was given then.
if pkill -x cloudflared; then
    echo "Stopped the tunnels a previous run left."
fi
# A state left means the last run ended without stopping, so the tunnels went
# at its last write; a clean stop removes it, having logged each.
lost_at=''
if grep -qxE 'serving|waiting' "$STATE_FILE" 2>/dev/null; then
    lost_at="$(stat -f %m "$STATE_FILE")"
fi
rm -f "$OLD_PID_FILE" # (TEMPORARY, with OLD_PID_FILE.)
find_own
log '*' lost "$lost_at"
trap cleanup EXIT
# Noted, and acted on after the read in the loop: bash 3.2 times read -t with
# an alarm, which, when a trap exits mid-read, fires during cleanup and spins.
stop=''
trap 'stop=129' HUP
trap 'stop=130' INT
trap 'stop=143' TERM

# How long Bitview may stay behind the tip, in seconds, checked every minute,
# before this mini's own tunnel goes down. Steady, the workload looks as often.
STUCK_AFTER=600
CHECK_EVERY=60

# Serve while the other workloads run. While one is down, the tunnels are
# down too, so the other servers serve, and they come back once it serves
# again. Bitview stuck behind the tip would serve on what it has: then only
# this mini's own tunnel goes down, so Cloudflare's alert names it, while the
# shared ones serve on, as the other servers may be stuck as well; it comes
# back once Bitview reaches the tip.
serving=''
applied=''
waiting=''
OWN=''
while :; do
    tokens="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
    if [ "$tokens" != "$applied" ]; then
        apply_tokens "$tokens"
        applied="$tokens"
    fi
    if ! backends_running; then
        if [ -n "$serving" ]; then
            echo "bitcoind, bitviewd, or bitview_mcp is down; the tunnels wait for it." >&2
            for index in "${!NAMES[@]}"; do
                stop_tunnel "$index"
            done
            serving=''
        fi
    elif [ -z "$serving" ]; then
        if answering && at_tip; then
            serving=1 waiting='' behind_since='' checked=$SECONDS
            for index in "${!NAMES[@]}"; do
                start_tunnel "$index"
            done
        elif [ -z "$waiting" ]; then
            echo "Waiting for Bitview to reach the tip and both servers to answer..."
            waiting=1
        fi
    else
        for index in "${!NAMES[@]}"; do
            pid="${PIDS[$index]:-}"
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                status=0
                wait "$pid" 2>/dev/null || status=$?
                echo "Tunnel ${NAMES[$index]} exited with status $status; it starts again in 10 seconds." >&2
                unset "PIDS[$index]" "PORTS[$index]"
                EXITED[$index]=$SECONDS
            elif [ -n "${EXITED[$index]:-}" ] && [ $((SECONDS - EXITED[index])) -ge 10 ]; then
                start_tunnel "$index"
            fi
        done
        if [ -n "$OWN" ] && [ $((SECONDS - checked)) -ge "$CHECK_EVERY" ]; then
            checked=$SECONDS
            if at_tip; then
                behind_since=''
                if [ -z "${PIDS[$OWN]:-}" ] && [ -z "${EXITED[$OWN]:-}" ]; then
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
    fi
    [ -n "$self" ] || find_own
    reap
    record_state
    # A second while something changes, a minute once steady, cut short by a
    # line on the pipe (set, state, a server ending) or a cloudflared ending,
    # looked for each second with kill -0, which starts no process.
    if [ -n "$steady" ]; then pause=$CHECK_EVERY; else pause=1; fi
    while [ "$pause" -gt 0 ] && cloudflareds_run; do
        woken=''
        read -r -t 1 -u 3 _ && woken=1
        [ -z "$stop" ] || exit "$stop"
        [ -z "$woken" ] || break
        pause=$((pause - 1))
    done
done
