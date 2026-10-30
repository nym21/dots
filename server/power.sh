#!/usr/bin/env bash
set -euo pipefail

# Restart or shut down this mini cleanly, as ship reboot and ship shutdown, and
# fleet reboot and fleet shutdown, which lend it the password: its workloads
# stop first, as shutting down would end Bitcoin Core mid-write, and the boot
# daemon starts them again. As root, with the password fleet lends, else
# asking on the terminal, checked before anything stops.
#
#   power.sh reboot      restart this mini
#   power.sh shutdown    turn it off

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTS_DIR="$SERVER_DIR/.."

case "$#:${1:-}" in
    1:reboot) flag=-r ;;
    1:shutdown) flag=-h ;;
    *)
        echo "Usage: $0 reboot | shutdown" >&2
        exit 1
        ;;
esac

source "$DOTS_DIR/shared/lent.sh"
if [ -z "$lent_password" ] && [ ! -t 0 ]; then
    echo "No terminal to ask the password on: run this in one, or fleet $1." >&2
    exit 1
fi
as_root -v

# Any way this ends short of the shutdown starts them again, but the
# shutdown's own signal, as they would start while macOS stops.
trap '"$SERVER_DIR/workloads.sh" start' EXIT
trap 'trap - EXIT; exit 143' TERM
"$SERVER_DIR/workloads.sh" stop
echo "Shutting down to $1..."
as_root shutdown "$flag" now
# The shutdown ends this script; still here after 10 minutes, it did not come.
sleep 600
echo "This mini did not $1; starting the workloads again." >&2
