#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/external.sh"

DATA_DIR="$EXTERNAL_VOLUME/bitcoin"

mkdir -p "$DATA_DIR"

exec bitcoind -datadir="$DATA_DIR" "$@"
