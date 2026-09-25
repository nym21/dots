#!/usr/bin/env bash
set -e

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script only supports macOS." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in administrator, not with sudo." >&2
    exit 1
fi

echo "Checking for macOS updates..."
softwareupdate --list --product-types macOS

echo
echo "This will install every available macOS update and may restart the Mac."
read -r -p "Continue? [y/N] " reply
case "$reply" in
    y|Y|yes|Yes|YES) ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

sudo -v
sudo softwareupdate \
    --install \
    --all \
    --os-only \
    --restart \
    --agree-to-license
