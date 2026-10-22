#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitviewd, as the bitviewd block of workloads.sh does.
# dots install chooses the version.

if [ "$#" -ne 0 ]; then
    echo "Usage: $0 (dots install chooses the version)" >&2
    exit 1
fi

source "$(dirname "$0")/external.sh"

mkdir -p "$EXTERNAL_VOLUME/bitview"

RUST_BACKTRACE=1 LOG=debug exec bitviewd \
    --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
    --bitviewdir "$EXTERNAL_VOLUME/bitview" \
    --cdn true
