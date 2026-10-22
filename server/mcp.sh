#!/usr/bin/env bash

set -euo pipefail

# Install bitview_mcp from crates.io, or from a branch of the official
# repository, and restart the com.local.bitview-mcp daemon on it. The daemon
# runs this script with --run, which starts the installed bitview_mcp without
# installing anything, so reboots and restarts keep the version installed here.

SERVICE="com.local.bitview-mcp"

if [ "$#" -eq 1 ] && [ "$1" = "--run" ]; then
    LOG=debug exec bitview_mcp \
        --api https://bitview.space \
        --url https://mcp.bitview.space/ \
        --name Bitview
fi

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --run]" >&2
    exit 1
fi

install_args=(--locked)
if [ "$#" -eq 1 ]; then
    install_args+=(--git https://github.com/bitcoinresearchkit/mono --branch "$1")
fi

cargo install "${install_args[@]}" bitview_mcp

if [ -f "/Library/LaunchDaemons/$SERVICE.plist" ]; then
    sudo launchctl kickstart -k "system/$SERVICE"
    echo "Restarted $SERVICE on the installed bitview_mcp."
else
    echo "Installed bitview_mcp. Start the daemons with ./server/services.sh."
fi
