#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch]" >&2
    exit 1
fi

install_args=(--locked)
if [ "$#" -eq 1 ]; then
    install_args+=(--git https://github.com/bitcoinresearchkit/mono --branch "$1")
fi

rustup update

RUSTFLAGS="-C target-cpu=native" cargo install "${install_args[@]}" bitviewd_bench

mkdir -p /Volumes/External/bitview

exec bitviewd_bench \
    --bitcoindir /Volumes/External/bitcoin \
    --bitviewdir /Volumes/External/bitview
