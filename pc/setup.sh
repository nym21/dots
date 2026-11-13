#!/usr/bin/env bash
set -e

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

# shellcheck disable=SC2034 # read by shared/setup.sh
ROLE=pc
source "$(dirname "$0")/../shared/setup.sh"

shared_setup

update_cargo_hawk
install_fleet_auto

# --- Agents ---
echo "Merging Codex and Claude Code settings..."
merge_agent_settings

# This Mac never sleeps, on battery or with its lid closed too, so T3 and its
# agents, fleet auto, the node and the tunnels keep running; no deep sleep or
# Power Nap wakes either. Its display stays on with no screen saver, so the
# screen never locks, which iPhone Mirroring's automatic sign-in needs: with
# the lid closed, an attached display (an HDMI dummy) keeps it on.
sudo pmset -a sleep 0 displaysleep 0 disablesleep 1 standby 0 powernap 0
defaults -currentHost write com.apple.screensaver idleTime -int 0

# --- Mullvad VPN ---
# It updates itself, which Homebrew cannot adopt without App Management
# access, so its cask installs it only when missing, rather than the Brewfile.
if [ ! -d "/Applications/Mullvad VPN.app" ]; then
    echo "Installing Mullvad VPN..."
    brew install --cask mullvad-vpn
fi
# Mullvad's defaults, but for what something here needs. Tailscale's packets,
# tssh's among them, need an MTU of 1380 in its tunnel: on its own, Mullvad
# lowers it below what they fit in. The local network stays reachable, and it
# connects at login. Its DNS blocking stays off, as each of its lists blocks
# T3 Connect's relay. The account is logged in by hand.
mullvad tunnel set mtu 1380
mullvad lan set allow
mullvad auto-connect set on
# cloudflared and tssh's tailscaled are excluded from it (pc/split-tunnel.sh
# says why).
mullvad split-tunnel set on
"$ROLE_DIR/split-tunnel.sh"

# This Mac's own node, which its Bitview reads.
"$ROLE_DIR/bitcoin.sh"

# The home video server, a private repo: Transmission through Mullvad, files
# made ready for the phone, and a web app on port 8080.
[ -d ~/Developer/stream ] || git clone git@github.com:nym21/stream.git ~/Developer/stream
~/Developer/stream/install.sh

mkdir -p ~/.local/bin
link "$ROLE_DIR/tssh" ~/.local/bin/tssh
link "$ROLE_DIR/tcopy" ~/.local/bin/tcopy
link "$ROLE_DIR/tscreen" ~/.local/bin/tscreen
link "$ROLE_DIR/trex" ~/.local/bin/trex
link "$ROLE_DIR/rex" ~/.local/bin/rex
link "$ROLE_DIR/cf" ~/.local/bin/cf
echo "Installing Cloudflare's cf..."
install_cf
# Cloned over HTTPS, as by bootstrap, dots pushes over SSH: the workstation
# makes every Git write.
if [ "$(git -C "$ROLE_DIR/.." remote get-url origin)" = https://github.com/nym21/dots.git ]; then
    git -C "$ROLE_DIR/.." remote set-url --push origin git@github.com:nym21/dots.git
fi

# FileVault requires the login password and returns a personal recovery key.
if fdesetup isactive >/dev/null 2>&1; then
    echo "FileVault is already enabled."
else
    echo "Enabling FileVault..."
    echo "Save the recovery key somewhere other than this Mac."
    sudo fdesetup enable -user "$(id -un)" -prompt
fi

missing="$(missing_steps)"
echo
echo "PC setup complete."
if [ -n "$missing" ]; then
    echo "Remaining:"
    sed 's/^/  - /' <<< "$missing"
fi
