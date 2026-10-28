#!/usr/bin/env bash
set -euo pipefail

# Install the newest macOS update or upgrade, if any, and restart: the last
# step of ship update. It downloads while everything keeps running, then gives
# 30 seconds to cancel before stopping a server's workloads cleanly, which
# come back at boot, or at once should the install not restart the Mac. With
# macOS current, it installs the other updates, such as Safari or the Command
# Line Tools, the newest of each. With --download, for ship fetch and fleet,
# it restarts nothing: it installs those, or downloads a macOS update. With
# --same-major, as fleet auto runs it, a major upgrade waits for a run by hand.
#
# macOS asks for its owner's password to download an update as well as to
# install it, even as root: a terminal's, or without one the password fleet
# lends a server for this one job, which needs no countdown.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
source "$DOTS_DIR/shared/lent.sh"
# The macOS update --download readied, which fleet update installs; ship
# status shows it until then.
WAITING="$HOME/.config/dots/macos-downloaded"
download=0
same_major=0
for arg; do
    case "$arg" in
        --download) download=1 ;;
        --same-major) same_major=1 ;;
        *)
            echo "Usage: $0 [--download] [--same-major]" >&2
            exit 1
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in administrator, not with sudo." >&2
    exit 1
fi

echo "Checking for macOS updates..."
current="$(sw_vers -productVersion)"
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
    rm -f "$WAITING"
    echo "macOS $current and its other software are up to date."
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
    done < <(cut -d '|' -f 1 <<< "$UPDATES" | sort -u | grep -vx macOS)
}

# softwareupdate ARGS... as root, as the Mac's owner: with the lent password,
# or asking on the terminal.
as_owner() {
    if [ -n "$lent_password" ]; then
        printf '%s\n' "$lent_password" | sudo -n softwareupdate "$@" --user "$(id -un)" --stdinpass
    else
        sudo softwareupdate "$@"
    fi
}

macos="$(newest macOS)"
if [ "$same_major" -eq 1 ] && [ -n "$macos" ]; then
    IFS='|' read -r _ version _ <<< "$macos"
    if [ "${version%%.*}" != "${current%%.*}" ]; then
        echo "macOS $version, a major upgrade, waits for fleet update run by hand."
        macos="$(awk -F '|' -v major="${current%%.*}." '$1 == "macOS" && index($2, major) == 1 { line = $0 }
            END { if (line) print line }' <<< "$UPDATES")"
    fi
fi

if [ "$download" -eq 1 ]; then
    if [ -z "$macos" ]; then
        rm -f "$WAITING"
        # Without a password, which /etc/sudoers.d/dots allows for softwareupdate.
        install_others -n || echo "Could not install them without a password; ship update will."
        exit 0
    fi
    IFS='|' read -r _ version label <<< "$macos"
    if [ -z "$lent_password" ]; then
        echo "Could not download macOS $version without the password, which fleet update lends."
        exit 0
    fi
    echo "Downloading macOS $version, from $current..."
    if as_owner --download "$label"; then
        mkdir -p "$(dirname "$WAITING")"
        echo "$version" > "$WAITING"
        echo "macOS $version is downloaded."
    else
        echo "Could not download macOS $version; fleet update tries again."
    fi
    exit 0
fi

if [ -z "$macos" ]; then
    rm -f "$WAITING"
    # Asks for the password only if a rule is missing, then needs none.
    with_lent "$DOTS_DIR/shared/sudoers.sh"
    install_others
    exit 0
fi

IFS='|' read -r _ version label <<< "$macos"
if [ -z "$lent_password" ] && [ ! -t 0 ]; then
    echo "macOS $version is out; run ship update in a terminal to install it."
    exit 0
fi
with_lent "$DOTS_DIR/shared/sudoers.sh"
echo "Downloading macOS $version, from $current..."
as_owner --download "$label"
if [ -z "$lent_password" ]; then
    echo "Installing macOS $version and restarting in 30 seconds; Ctrl-C to skip."
    sleep 30
fi

# The restart would end the workloads abruptly, so they stop first, and the
# boot daemon starts them. Any way this ends short of the restart starts them
# again, but the shutdown's own signal, as they would start while macOS stops.
role="$(cat "$HOME/.config/dots/role" 2>/dev/null || true)"
if [ "$role" = server ]; then
    trap '"$DOTS_DIR/server/workloads.sh" start' EXIT
    trap 'trap - EXIT; exit 143' TERM
    "$DOTS_DIR/server/workloads.sh" stop
fi
echo "Installing macOS $version..."
as_owner --install "$label" --restart --agree-to-license
# The restart ends this script; still here after 10 minutes, it did not come.
if [ "$role" = server ]; then
    sleep 600
    echo "macOS $version did not restart this Mac; starting the workloads again." >&2
fi
