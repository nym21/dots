#!/usr/bin/env bash
set -e

brew upgrade
brew cleanup
cargo install-update --all --locked

# Restart last: a server update may be running over this Tailscale connection.
if launchctl print system/com.local.tailscaled >/dev/null 2>&1; then
    sudo launchctl kickstart -k system/com.local.tailscaled
fi
