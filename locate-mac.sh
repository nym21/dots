#!/usr/bin/env bash
set -e

echo "Playing a short sound repeatedly on $(hostname). Press Ctrl-C to stop."
echo "Using the Mac's current audio output and volume."
trap 'exit 0' INT TERM HUP

while true; do
    /usr/bin/afplay /System/Library/Sounds/Ping.aiff
    sleep 1
done
