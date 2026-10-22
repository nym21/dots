#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch]" >&2
    exit 1
fi

# The benchmark reuses and writes Bitview's data.
if pgrep -x bitviewd >/dev/null; then
    echo "Stop bitviewd first: sudo launchctl bootout system/com.local.bitviewd" >&2
    exit 1
fi

install_args=(--locked)
if [ "$#" -eq 1 ]; then
    install_args+=(--git https://github.com/bitcoinresearchkit/mono --branch "$1")
fi

rustup update

RUSTFLAGS="-C target-cpu=native" cargo install "${install_args[@]}" bitviewd_bench

source "$(dirname "$0")/external.sh"
mkdir -p "$EXTERNAL_VOLUME/bitview/data"

exec bitviewd_bench \
    --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
    --bitviewdir "$EXTERNAL_VOLUME/bitview/data"
