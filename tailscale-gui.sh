#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
ENV_FILE="/private/var/root/Library/Containers/io.tailscale.ipn.macsys.network-extension/Data/tailscaled-env.txt"
ENV_DIR="${ENV_FILE%/*}"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Install Homebrew first." >&2
    exit 1
fi

if brew list --formula tailscale >/dev/null 2>&1 || launchctl print system/com.local.tailscaled >/dev/null 2>&1; then
    echo "Remove the Homebrew tailscale formula before installing the GUI app." >&2
    exit 1
fi

if [ ! -x "$APP" ]; then
    brew install --cask tailscale-app
fi

if [ ! -d "$ENV_DIR" ]; then
    open -a Tailscale
    echo "Approve the Tailscale system extension, then run this script again." >&2
    exit 0
fi

if ! sudo grep -qx 'TS_NO_LOGS_NO_SUPPORT=true' "$ENV_FILE" 2>/dev/null; then
    printf '\nTS_NO_LOGS_NO_SUPPORT=true\n' | sudo tee -a "$ENV_FILE" >/dev/null
fi

sudo "$APP" down-for-update
"$APP" rungui
"$APP" up
