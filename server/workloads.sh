#!/usr/bin/env bash

set -euo pipefail

# Start or stop Bitcoin Core, Bitview, the MCP server, and this mini's
# Cloudflare tunnels. Each runs in its own block of the Rex session "server",
# under the Rex server, whose Full Disk Access reaches the external volume and
# survives Rex updates. A workload that fails is logged, with the end of its
# output, and stays down to be looked at. Meanwhile the tunnels are down, so
# the other servers serve and Cloudflare's alert about this mini's own tunnel
# says so. Only the tunnels start again, 10 seconds later, as cloudflared
# gives up during a long network outage. The workloads start again at boot,
# after rex.sh restarts the Rex server, and on ship start.
#
#   workloads.sh start            start what is not running, in order
#   workloads.sh stop [NAME...]   stop all, or the NAMEs, cleanly and in order
#   workloads.sh boot             wait for the Rex server and the external
#                                 volume, then run start in its own block
#
# NAMEs are bitcoind, bitviewd, mcp, and tunnels.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION=server
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

source "$SERVER_DIR/crate.sh"

usage() {
    echo "Usage: $0 start | stop [bitcoind | bitviewd | mcp | tunnels]... | boot" >&2
    exit 1
}

rex() {
    command rex --autostart=false "$@"
}

script() {
    case "$1" in
        bitcoind) echo bitcoin.sh ;;
        bitviewd) echo bitview.sh ;;
        mcp) echo mcp.sh ;;
        tunnels) echo tunnels.sh ;;
        *) usage ;;
    esac
}

# A workload's processes, wherever they were started. Tunnels started before
# tunnels.sh run as bare cloudflared processes.
pids() {
    case "$1" in
        bitcoind) pgrep -x bitcoind ;;
        bitviewd) pgrep -x bitviewd ;;
        mcp) pgrep -x bitview_mcp ;;
        tunnels) pgrep -f server/tunnels.sh; pgrep -x cloudflared ;;
    esac || true
}

running() {
    [ -n "$(pids "$1")" ]
}

# The loop that runs workload $1 in its block, which may be waiting to
# restart it.
supervisor() {
    pgrep -f "server/workloads.sh supervise $1\$" || true
}

# Log that workload $1 exited with status $2, and keep the end of its output.
crashed() {
    local stamp own
    stamp="$(date +%Y-%m-%dT%H:%M:%S)"
    mkdir -p "$(dirname "$CRASH_LOG")"
    echo "$stamp $1 exited with status $2" >> "$CRASH_LOG"
    own="$(own_log "$1")"
    {
        rex capture -s "$SESSION" -b "$1" 2>/dev/null | tail -n 200 || true
        if [ -n "$own" ] && [ -f "$own" ]; then
            echo "--- The end of $own:"
            tail -n 200 "$own"
        fi
    } > "${CRASH_LOG%.log}-$1-$stamp.log"
}

# The log workload $1 writes itself rather than to its window, if any:
# Bitview's of the day, or Bitcoin Core's debug.log.
own_log() {
    case "$1" in
        bitviewd) find /Volumes/External/bitview/logs -name '????-??-??.txt' 2>/dev/null | sort | tail -1 ;;
        bitcoind) echo /Volumes/External/bitcoin/debug.log ;;
    esac
}

# Keep workload $1's window small, checked every ten minutes: once it holds
# over half a megabyte, clear it and print its last 1000 lines back, colors and
# all, this loop's output being the window's. The Rex app loads a window's
# whole scrollback, and Rex keeps no limit of its own yet. A capture fails past
# a megabyte, and then all of it goes. The workload keeps running. The clear
# runs in a subshell: called from this loop itself, it ends the loop.
trim_window() {
    local window
    while sleep 600; do
        if window="$(rex capture -s "$SESSION" -b "$1" --format=vt 2>/dev/null)"; then
            [ "${#window}" -gt 524288 ] || continue
            (rex block call -s "$SESSION" -b "$1" clear) </dev/null >/dev/null 2>&1 || continue
            tail -n 1000 <<< "$window" || true
        else
            (rex block call -s "$SESSION" -b "$1" clear) </dev/null >/dev/null 2>&1 || true
        fi
    done
}

# Run workload $1 until it exits, logging a failing exit; only the tunnels
# start again, 10 seconds later. TERM, which stop sends, passes on to the
# workload and ends the loop once it has exited. Each start of Bitview or the
# MCP server records the build it runs, and of the tunnels their tokens, in
# RUNNING_DIR. Meanwhile its window is kept small.
supervise() {
    local name="$1" command crate='' pid='' status stopping=0 trimmer
    command="$SERVER_DIR/$(script "$name")"
    case "$name" in
        bitviewd) crate=bitviewd ;;
        mcp) crate=bitview_mcp ;;
    esac
    trim_window "$name" &
    trimmer=$!
    trap 'kill "$trimmer" 2>/dev/null || true' EXIT
    trap 'stopping=1; kill -TERM "$pid" 2>/dev/null || true' TERM INT HUP
    while :; do
        mkdir -p "$RUNNING_DIR"
        if [ -n "$crate" ]; then
            installed "$crate" > "$RUNNING_DIR/$crate" || true
        elif [ "$name" = tunnels ]; then
            tokens_digest > "$RUNNING_DIR/tunnels"
        fi
        "$command" &
        pid=$!
        status=0
        wait "$pid" || status=$?
        # A trapped signal returns wait early; wait for the exit itself.
        while kill -0 "$pid" 2>/dev/null; do
            status=0
            wait "$pid" || status=$?
        done
        if [ "$stopping" -eq 1 ] || [ "$status" -eq 0 ]; then
            exit "$status"
        fi
        crashed "$name" "$status"
        if [ "$name" != tunnels ]; then
            echo "$name exited with status $status, logged in $CRASH_LOG; it stays down until ship start."
            exit "$status"
        fi
        echo "$name exited with status $status; restarting in 10 seconds."
        sleep 10 &
        wait $! || true
        [ "$stopping" -eq 0 ] || exit 0
    done
}

session_exists() {
    rex ls --json | jq -e --arg session "$SESSION" \
        '.sessions[] | select(.label == $session)' >/dev/null
}

# Run COMMAND in the block LABEL, in a window named LABEL too, which the Rex
# app lists, replacing every one a previous run left with its last output, by
# ID: closing by label fails once two share it, and each run would add one.
run_block() {
    local label="$1" block window
    shift
    if session_exists; then
        for block in $(rex block ls -s "$SESSION" --json |
            jq -r --arg label "$label" '.blocks[] | select(.label == $label) | .block_id'); do
            rex block close -s "$SESSION" "$block" >/dev/null 2>&1 || true
        done
        window="$(rex run -s "$SESSION" --label "$label" --keep-open --focus=false -c "$HOME" --json \
            -- "$@" | jq -r .window_id)"
        rex window rename -s "$SESSION" "$window" "$label" >/dev/null
    else
        block="$(rex new "$SESSION" --window "$label" --keep-open -c "$HOME" --json \
            -- "$@" | jq -r '.initial_windows[0].block_ids[0]')"
        rex block rename -s "$SESSION" "$block" "$label" >/dev/null
    fi
}

# Start workload $1 in its block. Unless $2 is "no-check", fail if it exits at
# once.
start_one() {
    local name="$1"
    if running "$name" || [ -n "$(supervisor "$name")" ]; then
        echo "$name: already running"
        return 0
    fi
    echo "$name: starting"
    run_block "$name" "$SERVER_DIR/workloads.sh" supervise "$name"
    if [ "${2:-}" != no-check ]; then
        sleep 3
        if ! running "$name"; then
            echo "$name exited; its block in the Rex session $SESSION shows why." >&2
            exit 1
        fi
    fi
}

# One start at a time: after a Rex restart, its boot starts the workloads while
# ship apply would too, and of each workload started twice, the second fails
# on the first's data. A later start waits, then finds them running. A start
# that died leaves its lock to the next, as does one from before the Mac last
# started, whose number another process may have, or one left without its
# number for a minute. Kept out of the caches, which a cleaner may empty while
# a start holds it.
START_LOCK="$HOME/Library/Application Support/dots/workloads-start.lock"
lock_start() {
    local waiting='' booted taken
    booted="$(sysctl -n kern.boottime | sed -E 's/^[{] sec = ([0-9]+),.*/\1/')"
    mkdir -p "$(dirname "$START_LOCK")"
    until mkdir "$START_LOCK" 2>/dev/null; do
        taken="$(stat -f %m "$START_LOCK" 2>/dev/null || echo 0)"
        if [ "$taken" -lt "$booted" ] ||
            { [ -f "$START_LOCK/pid" ] && ! kill -0 "$(cat "$START_LOCK/pid" 2>/dev/null)" 2>/dev/null; } ||
            { [ ! -s "$START_LOCK/pid" ] && [ $(($(date +%s) - taken)) -gt 60 ]; }; then
            rm -rf "$START_LOCK"
            continue
        fi
        [ -n "$waiting" ] || echo "Waiting for another start to finish..."
        waiting=1
        sleep 1
    done
    echo $$ > "$START_LOCK/pid"
    trap 'rm -rf "$START_LOCK"' EXIT
}

start() {
    lock_start
    source "$SERVER_DIR/external.sh"

    start_one bitcoind
    # Bitview needs Bitcoin Core's RPC, which answers once its index is loaded.
    if ! bitcoin-cli -datadir="$EXTERNAL_VOLUME/bitcoin" getblockcount >/dev/null 2>&1; then
        echo "Waiting for Bitcoin Core's RPC..."
        until bitcoin-cli -datadir="$EXTERNAL_VOLUME/bitcoin" getblockcount >/dev/null 2>&1; do
            if ! running bitcoind; then
                echo "bitcoind exited; its block in the Rex session $SESSION shows why." >&2
                exit 1
            fi
            sleep 2
        done
    fi
    start_one bitviewd
    start_one mcp
    # The tunnels wait in their block until Bitview reaches the tip, or report
    # that none runs on this mini.
    start_one tunnels no-check
}

# Stop workload $1 with TERM and wait for it to shut down cleanly, which can
# take Bitcoin Core minutes.
stop_one() {
    local name="$1" waited=0 loop
    loop="$(supervisor "$name")"
    running "$name" || [ -n "$loop" ] || return 0
    echo "$name: stopping"
    # The loop passes TERM on once; a workload started without one gets it here.
    # shellcheck disable=SC2046,SC2086
    if [ -n "$loop" ]; then
        kill -TERM $loop 2>/dev/null || true
    else
        kill -TERM $(pids "$name") 2>/dev/null || true
    fi
    while running "$name" || [ -n "$(supervisor "$name")" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 1800 ]; then
            echo "$name still runs after 30 minutes; stopping here." >&2
            exit 1
        fi
        if [ $((waited % 30)) -eq 0 ]; then
            echo "  still stopping after ${waited}s"
        fi
    done
    echo "  stopped after ${waited}s"
}

stop() {
    local names="${*:-bitcoind bitviewd mcp tunnels}" name
    for name in $names; do
        script "$name" >/dev/null
    done
    # The tunnels first, so no traffic reaches a stopping server, Bitcoin Core
    # last.
    for name in tunnels mcp bitviewd bitcoind; do
        case " $names " in
            *" $name "*) stop_one "$name" ;;
        esac
    done
}

# Run by the com.local.workloads daemon at boot and by rex.sh after it
# restarts the Rex server. start runs in a block, under the Rex server, since
# reaching Bitcoin Core needs its access to the external volume.
boot() {
    local waited=0
    # A password fleet lent a job the restart ended before it read it.
    rm -f "$HOME/.config/dots/password"
    until rex ls >/dev/null 2>&1 && (source "$SERVER_DIR/external.sh") 2>/dev/null; do
        if [ "$waited" -ge 600 ]; then
            echo "The Rex server or the external volume is still missing after 10 minutes." >&2
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    run_block start "$SERVER_DIR/workloads.sh" start
    echo "Started workloads.sh start in the Rex session $SESSION."
}

case "${1:-}" in
    start)
        [ "$#" -eq 1 ] || usage
        start
        ;;
    boot)
        [ "$#" -eq 1 ] || usage
        boot
        ;;
    supervise)
        [ "$#" -eq 2 ] || usage
        script "$2" >/dev/null
        supervise "$2"
        ;;
    stop)
        shift
        stop "$@"
        ;;
    *)
        usage
        ;;
esac
