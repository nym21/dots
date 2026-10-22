#!/usr/bin/env bash

set -euo pipefail

# Set this mini's mode and run it: install Bitview and the MCP server from
# crates.io (prod), a branch of the official repository (next), or the
# checkout in ~/Developer/mono (local), restart the workloads whose binary
# changed, and start whatever is not running. A run with nothing new leaves a
# running mini alone.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local]" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

checksum() {
    shasum "$HOME/.cargo/bin/$1" 2>/dev/null || true
}

bitviewd_before="$(checksum bitviewd)"
mcp_before="$(checksum bitview_mcp)"

rustup update
install_crate bitviewd "$@"
install_crate bitview_mcp "$@"

# The tunnels follow Bitview, whose install sets the mode, and stop before a
# server restarts so no traffic reaches it meanwhile.
restart=''
if [ "$(checksum bitviewd)" != "$bitviewd_before" ]; then
    restart="$restart tunnels bitviewd"
fi
if [ "$(checksum bitview_mcp)" != "$mcp_before" ]; then
    restart="$restart tunnels mcp"
fi
if [ -n "$restart" ]; then
    # shellcheck disable=SC2086
    "$SERVER_DIR/workloads.sh" stop $restart
fi

"$SERVER_DIR/workloads.sh" start
