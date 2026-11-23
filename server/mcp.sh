#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitview_mcp, as the mcp block of workloads.sh does.
# ship install chooses the version. It queries this mini's own Bitview, so
# its tools run against the same version whichever role fleet gives the mini,
# and a swap of roles restarts nothing.

if [ "$#" -ne 0 ]; then
    echo "Usage: $0 (ship install chooses the version)" >&2
    exit 1
fi

LOG=debug exec bitview_mcp \
    --api http://127.0.0.1:3110 \
    --url https://mcp.bitview.space/ \
    --name Bitview
