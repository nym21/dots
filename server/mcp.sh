#!/usr/bin/env bash

set -euo pipefail

cargo install --locked bitview_mcp

LOG=debug exec bitview_mcp \
    --api https://bitview.space \
    --url https://mcp.bitview.space/ \
    --name Bitview
