#!/usr/bin/env bash
set -euo pipefail

# Install the newest macOS update or upgrade, if any, and restart: the last
# step of ship update. It downloads while everything keeps running, then gives
# 30 seconds to cancel before stopping a server's workloads cleanly, which
# come back at boot. With macOS current, it installs the other updates, such
# as Safari or the Command Line Tools, the newest of each. With --download, it
# only downloads a macOS update, for ship fetch.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
download=0
case "$*" in
    '') ;;
    --download) download=1 ;;
    *)
        echo "Usage: $0 [--download]" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in administrator, not with sudo." >&2
    exit 1
fi

echo "Checking for macOS updates..."
LIST="$(softwareupdate --list 2>&1)"
# One line per update, newest version last within each product: product|version|label.
UPDATES="$(printf '%s\n' "$LIST" | awk '
    /^\* Label: / { label = substr($0, index($0, ": ") + 2); next }
    label != "" && /Title: / {
        title = $0; sub(/.*Title: /, "", title); sub(/, Version: .*/, "", title)
        version = $0; sub(/.*Version: /, "", version); sub(/,.*/, "", version)
        product = title; sub(/ [0-9][0-9.]*$/, "", product)
        if (product ~ /^macOS/) product = "macOS"
        print product "|" version "|" label
        label = ""
    }
' | sort -t '|' -k1,1 -k2,2V)"

if [ -z "$UPDATES" ]; then
    if ! grep -q "No new software available" <<< "$LIST"; then
        printf '%s\n' "$LIST" >&2
        echo "Could not read the list of updates." >&2
        exit 1
    fi
    echo "macOS $(sw_vers -productVersion) and its other software are up to date."
    exit 0
fi

newest() {
    awk -F '|' -v product="$1" '$1 == product { line = $0 } END { if (line) print line }' <<< "$UPDATES"
}

macos="$(newest macOS)"
if [ "$download" -eq 1 ]; then
    [ -n "$macos" ] || exit 0
    IFS='|' read -r _ version label <<< "$macos"
    echo "Downloading macOS $version, from $(sw_vers -productVersion)..."
    # Without a password, which /etc/sudoers.d/dots allows for softwareupdate.
    if sudo -n softwareupdate --download "$label" </dev/null; then
        echo "macOS $version is downloaded."
    else
        echo "Could not download macOS $version without a password; ship update will."
    fi
    exit 0
fi
# Asks for the password only if a rule is missing, then needs none.
"$DOTS_DIR/shared/sudoers.sh"
if [ -z "$macos" ]; then
    # Without a macOS update, install the newest of each other product.
    while IFS= read -r product; do
        IFS='|' read -r _ version label <<< "$(newest "$product")"
        echo "Installing $product $version..."
        sudo softwareupdate --install "$label" --agree-to-license </dev/null
    done < <(cut -d '|' -f 1 <<< "$UPDATES" | sort -u)
    exit 0
fi

IFS='|' read -r _ version label <<< "$macos"
echo "Downloading macOS $version, from $(sw_vers -productVersion)..."
sudo softwareupdate --download "$label"
# Installing macOS asks for the Mac owner's password, even as root.
if [ ! -t 0 ]; then
    echo "macOS $version is downloaded; run ship update in a terminal to install it."
    exit 0
fi
echo "Installing macOS $version and restarting in 30 seconds; Ctrl-C to skip."
sleep 30

# The restart would end the workloads abruptly; the boot daemon starts them.
role="$(cat "$HOME/.config/dots/role" 2>/dev/null || true)"
if [ "$role" = server ]; then
    "$DOTS_DIR/server/workloads.sh" stop
fi
if ! sudo softwareupdate --install "$label" --restart --agree-to-license; then
    [ "$role" != server ] || "$DOTS_DIR/server/workloads.sh" start
    exit 1
fi
