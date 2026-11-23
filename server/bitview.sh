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

# The site's public origin, which the MCP server at /mcp names itself by, the
# same on every mini whatever its mode.
site_url=https://bitview.space
# TEMPORARY, for the rollout of the MCP server into bitviewd (2026-11): delete
# once every mini runs a bitviewd that has --siteurl, a crates.io release
# included. One from before refuses the flag and does not start, and dots
# reaches a mini before its new build does, as when a fetch fails or the mini
# boots in between.
case "$(bitviewd --help)" in
    *--siteurl*) ;;
    *) site_url='' ;;
esac

RUST_BACKTRACE=1 LOG=debug exec bitviewd \
    --bitcoindir "$EXTERNAL_VOLUME/bitcoin" \
    --bitviewdir "$EXTERNAL_VOLUME/bitview" \
    "$@" \
    ${public_url:+--publicurl "$public_url"} \
    ${site_url:+--siteurl "$site_url"}
