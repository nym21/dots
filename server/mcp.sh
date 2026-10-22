#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitview_mcp, as the com.local.bitview-mcp daemon does.
# ./server/install.sh chooses the version.

if [ "$#" -ne 0 ]; then
    echo "Usage: $0 (./server/install.sh chooses the version)" >&2
    exit 1
fi

LOG=debug exec bitview_mcp \
    --api https://bitview.space \
    --url https://mcp.bitview.space/ \
    --name Bitview
