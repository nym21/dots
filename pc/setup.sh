#!/usr/bin/env bash
set -e

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

ROLE=pc
source "$(dirname "$0")/../shared/setup.sh"

# Configure Raycast before launch so it cannot cache the default opt-ins.
echo "Disabling Raycast analytics and error reporting..."
pkill -x Raycast 2>/dev/null || true
defaults write com.raycast.macos analytics_optOut -bool true
defaults write com.raycast.macos errorReporting_optOut -bool true

shared_setup

mkdir -p ~/.config/zed ~/.local/bin
link "$ROLE_DIR/tssh" ~/.local/bin/tssh
git config --global core.editor "zed --wait"
link "$ROLE_DIR/home/.config/zed/settings.json" ~/.config/zed/settings.json

# FileVault requires the login password and returns a personal recovery key.
if fdesetup isactive >/dev/null 2>&1; then
    echo "FileVault is already enabled."
else
    echo "Enabling FileVault..."
    echo "Save the recovery key somewhere other than this Mac."
    sudo fdesetup enable -user "$(id -un)" -prompt
fi

echo
echo "PC setup complete."
echo "Manual steps remaining:"
echo "  - Enable Lockdown Mode: System Settings > Privacy & Security > Lockdown Mode > Turn On & Restart."
echo "  - If you postpone Lockdown Mode, restart your terminal manually."
