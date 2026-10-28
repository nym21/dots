#!/usr/bin/env bash
set -euo pipefail

# Install the newest macOS update or upgrade, if any, and restart: the last
# step of ship update. It downloads while everything keeps running, then gives
# 30 seconds to cancel before stopping a server's workloads cleanly, which
# come back at boot. With macOS current, it installs the other updates, such
# as Safari or the Command Line Tools, the newest of each. With --download, for
# ship fetch, it restarts nothing: it installs those, or downloads a macOS
# update.
#
# macOS asks for its owner's password to download an update as well as to
# install it, even as root: a terminal's, or without one the password fleet
# lends a server for a run, which needs no countdown.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# The macOS update --download readied, which fleet update installs; ship
# status shows it until then.
WAITING="$HOME/.config/dots/macos-downloaded"
lent=0
if [ ! -t 0 ] && [ -s "$HOME/.config/dots/password" ]; then
    lent=1
    export SUDO_ASKPASS="$DOTS_DIR/shared/askpass.sh"
fi
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

# Install the newest of each product but macOS, which restarts nothing, with
# sudo's OPTIONS.
install_others() {
    local product version label
    while IFS= read -r product; do
        IFS='|' read -r _ version label <<< "$(newest "$product")"
        echo "Installing $product $version..."
        sudo "$@" softwareupdate --install "$label" --agree-to-license </dev/null
    done < <(cut -d '|' -f 1 <<< "$UPDATES" | sort -u)
}

# softwareupdate ARGS... as root, as the Mac's owner: with the lent password,
# or asking on the terminal.
as_owner() {
    if [ "$lent" -eq 1 ]; then
        "$SUDO_ASKPASS" | sudo softwareupdate "$@" --user "$(id -un)" --stdinpass
    else
        sudo softwareupdate "$@"
    fi
}

macos="$(newest macOS)"
if [ "$download" -eq 1 ]; then
    if [ -z "$macos" ]; then
        rm -f "$WAITING"
        # Without a password, which /etc/sudoers.d/dots allows for softwareupdate.
        install_others -n || echo "Could not install them without a password; ship update will."
        exit 0
    fi
    IFS='|' read -r _ version label <<< "$macos"
    # Without the lent password, macOS downloads it in the background once
    # Apple offers it to this Mac, and fleet update before installing it.
    if [ "$lent" -eq 0 ]; then
        echo "Could not download macOS $version without the password; fleet update will."
        exit 0
    fi
    echo "Downloading macOS $version, from $(sw_vers -productVersion)..."
    if as_owner --download "$label"; then
        mkdir -p "$(dirname "$WAITING")"
        echo "$version" > "$WAITING"
        echo "macOS $version is downloaded."
    else
        echo "Could not download macOS $version; fleet update will."
    fi
    exit 0
fi
# Asks for the password only if a rule is missing, then needs none.
"$DOTS_DIR/shared/sudoers.sh"
if [ -z "$macos" ]; then
    install_others
    exit 0
fi

IFS='|' read -r _ version label <<< "$macos"
if [ "$lent" -eq 0 ] && [ ! -t 0 ]; then
    echo "macOS $version is out; run ship update in a terminal to install it."
    exit 0
fi
echo "Downloading macOS $version, from $(sw_vers -productVersion)..."
as_owner --download "$label"
if [ "$lent" -eq 0 ]; then
    echo "Installing macOS $version and restarting in 30 seconds; Ctrl-C to skip."
    sleep 30
fi

# The restart would end the workloads abruptly; the boot daemon starts them.
role="$(cat "$HOME/.config/dots/role" 2>/dev/null || true)"
if [ "$role" = server ]; then
    "$DOTS_DIR/server/workloads.sh" stop
fi
if ! as_owner --install "$label" --restart --agree-to-license; then
    [ "$role" != server ] || "$DOTS_DIR/server/workloads.sh" start
    exit 1
fi
