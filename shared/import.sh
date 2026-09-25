#!/usr/bin/env bash
set -e

ROLE="${1:-}"
case "$ROLE" in
    pc|server) ;;
    *)
        echo "Usage: $0 pc|server" >&2
        exit 1
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This setup only supports macOS." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTS_DIR="$(dirname "$SHARED_DIR")"
PC_DIR="$DOTS_DIR/pc"
SERVER_DIR="$DOTS_DIR/server"
ROLE_DIR="$DOTS_DIR/$ROLE"

source "$SHARED_DIR/setup.sh"
source "$ROLE_DIR/setup.sh"

# Server Full Disk Access is checked before packages, links, or system changes.
role_prepare
shared_setup
role_setup

echo
echo "$ROLE import complete."
role_finish
