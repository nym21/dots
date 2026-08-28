#!/usr/bin/env bash
set -e

brew upgrade

if launchctl print system/com.local.tailscaled >/dev/null 2>&1; then
    sudo launchctl kickstart -k system/com.local.tailscaled
fi

cargo install-update --all --locked
