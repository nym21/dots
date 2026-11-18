#!/usr/bin/env bash

set -euo pipefail

# Run the installed bitviewd, as the bitviewd block of workloads.sh does.
# ship install chooses the version.

case "$#:${1:-}" in
    0: | 1:--cache-key) action="${1:-}" ;;
    *) echo "Usage: $0 [--cache-key] (ship install chooses the version)" >&2; exit 1 ;;
esac

# Record the arguments that change what the edge can hold, so changing them
# restarts Bitview even when the installed build is unchanged.
set -- --cdn true
if [ "$action" = --cache-key ]; then
    printf '%s\0' "$@" | shasum | cut -d ' ' -f 1
    exit
fi

source "$(dirname "$0")/external.sh"

mkdir -p "$EXTERNAL_VOLUME/bitview"

# This mini's own address, SERVER.bitview.space, which fleet update writes.
public_url="$(cat ~/.config/dots/public-url 2>/dev/null || true)"

RUST_BACKTRACE=1 LOG=debug exec bitviewd \
    --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
    --bitviewdir "$EXTERNAL_VOLUME/bitview" \
    "$@" \
    ${public_url:+--publicurl "$public_url"}
