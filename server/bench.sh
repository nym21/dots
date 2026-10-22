#!/usr/bin/env bash

set -euo pipefail

SERVER_DIR="$(dirname "$0")"

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [prod | next | BRANCH | local]" >&2
    exit 1
fi

# The benchmark reuses and writes Bitview's data.
if pgrep -x bitviewd >/dev/null; then
    echo "Stop bitviewd first: ship stop tunnels bitviewd" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

rustup update

install_crate bitviewd_bench "${1:-prod}"

source "$SERVER_DIR/external.sh"
mkdir -p "$EXTERNAL_VOLUME/bitview"

exec bitviewd_bench \
    --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
    --bitviewdir "$EXTERNAL_VOLUME/bitview"
