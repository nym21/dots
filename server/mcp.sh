#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitview_mcp, as the mcp block of workloads.sh does.
# dots install chooses the version.

if [ "$#" -ne 0 ]; then
    echo "Usage: $0 (dots install chooses the version)" >&2
    exit 1
fi

LOG=debug exec bitview_mcp \
    --api https://bitview.space \
    --url https://mcp.bitview.space/ \
    --name Bitview
