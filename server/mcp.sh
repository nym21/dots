#!/usr/bin/env bash

set -euo pipefail

# Install bitview_mcp from crates.io, a branch of the official repository, or
# the checkout in ~/Developer/mono, and restart the com.local.bitview-mcp
# daemon on it. The daemon runs this script with --run, which starts the
# installed bitview_mcp without installing anything, so reboots and restarts
# keep the version installed here.

SERVER_DIR="$(dirname "$0")"
SERVICE="com.local.bitview-mcp"

if [ "$#" -eq 1 ] && [ "$1" = "--run" ]; then
    LOG=debug exec bitview_mcp \
        --api https://bitview.space \
        --url https://mcp.bitview.space/ \
        --name Bitview
fi

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local | --run]" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

install_crate bitview_mcp "$@"

if [ -f "/Library/LaunchDaemons/$SERVICE.plist" ]; then
    sudo launchctl kickstart -k "system/$SERVICE"
    echo "Restarted $SERVICE on the installed bitview_mcp."
else
    echo "Installed bitview_mcp. Start the daemons with ./server/services.sh."
fi
