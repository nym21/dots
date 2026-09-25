#!/usr/bin/env bash

set -euo pipefail

EXTERNAL_VOLUME="/Volumes/External"
DATA_DIR="$EXTERNAL_VOLUME/bitcoin"

if [ ! -d "$EXTERNAL_VOLUME" ] || ! mount | awk -v mountpoint="$EXTERNAL_VOLUME" \
    '$2 == "on" && $3 == mountpoint { found = 1 } END { exit !found }'; then
    echo "External volume is not mounted at $EXTERNAL_VOLUME." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"

exec bitcoind -datadir="$DATA_DIR" "$@"
