#!/usr/bin/env bash

set -euo pipefail

# Install bitviewd from crates.io, or from a branch of the official repository,
# and restart the com.local.bitviewd daemon on it. The daemon runs this script
# with --run, which starts the installed bitviewd without installing anything,
# so reboots and restarts keep the version installed here.

SERVICE="com.local.bitviewd"

if [ "$#" -eq 1 ] && [ "$1" = "--run" ]; then
    source "$(dirname "$0")/external.sh"
    mkdir -p "$EXTERNAL_VOLUME/bitview/data"
    RUST_BACKTRACE=1 LOG=debug exec bitviewd \
        --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
        --bitviewdir "$EXTERNAL_VOLUME/bitview/data" \
        --cdn true
fi

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --run]" >&2
    exit 1
fi

install_args=(--locked)
if [ "$#" -eq 1 ]; then
    install_args+=(--git https://github.com/bitcoinresearchkit/mono --branch "$1")
fi

rustup update

RUSTFLAGS="-C target-cpu=native" cargo install "${install_args[@]}" bitviewd

if [ -f "/Library/LaunchDaemons/$SERVICE.plist" ]; then
    sudo launchctl kickstart -k "system/$SERVICE"
    echo "Restarted $SERVICE on the installed bitviewd."
else
    echo "Installed bitviewd. Start the daemons with ./server/services.sh."
fi
