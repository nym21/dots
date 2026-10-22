#!/usr/bin/env bash

set -euo pipefail

# Start or stop Bitcoin Core, Bitview, the MCP server, and this mini's
# Cloudflare tunnels. Each runs in its own block of the Rex session "server",
# under the Rex server, whose Full Disk Access reaches the external volume and
# survives Rex updates. They start again at boot and after rex.sh restarts the
# Rex server, but not when one exits on its own: run start then.
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

session_exists() {
    rex ls --json | jq -e --arg session "$SESSION" \
        '.sessions[] | select(.label == $session)' >/dev/null
}

# Run COMMAND in the block LABEL, replacing the one a previous run left with
# its last output.
run_block() {
    local label="$1" block
    shift
    if session_exists; then
        rex block close -s "$SESSION" "$label" >/dev/null 2>&1 || true
        rex run -s "$SESSION" --label "$label" --keep-open --focus=false -c "$HOME" \
            -- "$@" >/dev/null
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
    if running "$name"; then
        echo "$name: already running"
        return 0
    fi
    echo "$name: starting"
    run_block "$name" "$SERVER_DIR/$(script "$name")"
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
    local name="$1" waited=0
    running "$name" || return 0
    echo "$name: stopping"
    # shellcheck disable=SC2046
    kill -TERM $(pids "$name") 2>/dev/null || true
    while running "$name"; do
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
    stop)
        shift
        stop "$@"
        ;;
    *)
        usage
        ;;
esac
