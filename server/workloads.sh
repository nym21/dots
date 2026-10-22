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
    local stamp
    stamp="$(date +%Y-%m-%dT%H:%M:%S)"
    mkdir -p "$(dirname "$CRASH_LOG")"
    echo "$stamp $1 exited with status $2" >> "$CRASH_LOG"
    rex capture -s "$SESSION" -b "$1" 2>/dev/null | tail -n 200 > "${CRASH_LOG%.log}-$1-$stamp.log" || true
}

# Run workload $1 until it exits, logging a failing exit; only the tunnels
# start again, 10 seconds later. TERM, which stop sends, passes on to the
# workload and ends the loop once it has exited. Each start of Bitview or the
# MCP server records the build it runs, in RUNNING_DIR.
supervise() {
    local name="$1" command crate='' pid='' status stopping=0
    command="$SERVER_DIR/$(script "$name")"
    case "$name" in
        bitviewd) crate=bitviewd ;;
        mcp) crate=bitview_mcp ;;
    esac
    trap 'stopping=1; kill -TERM "$pid" 2>/dev/null || true' TERM INT HUP
    while :; do
        if [ -n "$crate" ]; then
            mkdir -p "$RUNNING_DIR"
            installed "$crate" > "$RUNNING_DIR/$crate" || true
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
# app lists, replacing the one a previous run left with its last output.
run_block() {
    local label="$1" block window
    shift
    if session_exists; then
        rex block close -s "$SESSION" "$label" >/dev/null 2>&1 || true
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

start() {
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
