#!/usr/bin/env bash

set -euo pipefail

# Install bitviewd from crates.io, a branch of the official repository, or the
# checkout in ~/Developer/mono, and restart the com.local.bitviewd daemon on
# it. The daemon runs this script with --run, which starts the installed
# bitviewd without installing anything, so reboots and restarts keep the
# version installed here.

SERVER_DIR="$(dirname "$0")"
SERVICE="com.local.bitviewd"

if [ "$#" -eq 1 ] && [ "$1" = "--run" ]; then
    source "$SERVER_DIR/external.sh"
    mkdir -p "$EXTERNAL_VOLUME/bitview"
    RUST_BACKTRACE=1 LOG=debug exec bitviewd \
        --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
        --bitviewdir "$EXTERNAL_VOLUME/bitview" \
        --cdn true
fi

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local | --run]" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

rustup update

RUSTFLAGS="-C target-cpu=native" install_crate bitviewd "$@"

if [ -f "/Library/LaunchDaemons/$SERVICE.plist" ]; then
    sudo launchctl kickstart -k "system/$SERVICE"
    # The tunnels this mini runs follow how bitviewd is installed.
    if [ -f /Library/LaunchDaemons/com.local.tunnels.plist ]; then
        sudo launchctl kickstart -k system/com.local.tunnels
    fi
    echo "Restarted $SERVICE and the tunnels on the installed bitviewd."
else
    echo "Installed bitviewd. Start the daemons with ./server/services.sh."
fi
