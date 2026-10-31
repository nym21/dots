#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitview_mcp, as the mcp block of workloads.sh does.
# ship install chooses the version. It queries the public API of the mini's
# mode, through Cloudflare's cache, so its tools run against the same version
# of Bitview: bitview.space in release and prod, next.bitview.space in next. A mode without
# a public API, local or another branch, queries this mini's own Bitview.

if [ "$#" -ne 0 ]; then
    echo "Usage: $0 (ship install chooses the version)" >&2
    exit 1
fi

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SERVER_DIR/crate.sh"

mode=''
[ ! -r "$MODE_FILE" ] || read -r mode _ < "$MODE_FILE" || true
case "$mode" in
    release | prod) api=https://bitview.space ;;
    next) api=https://next.bitview.space ;;
    *) api=http://127.0.0.1:3110 ;;
esac

LOG=debug exec bitview_mcp \
    --api "$api" \
    --url https://mcp.bitview.space/ \
    --name Bitview
