#!/usr/bin/env bash
set -e

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

# shellcheck disable=SC2034 # read by shared/setup.sh
ROLE=pc
source "$(dirname "$0")/../shared/setup.sh"

# Configure Raycast before launch so it cannot cache the default opt-ins.
echo "Disabling Raycast analytics and error reporting..."
pkill -x Raycast 2>/dev/null || true
defaults write com.raycast.macos analytics_optOut -bool true
defaults write com.raycast.macos errorReporting_optOut -bool true

shared_setup

update_cargo_hawk
install_fleet_auto

# --- Agents ---
echo "Merging Codex and Claude Code settings..."
merge_agent_settings

# Time Machine backs up only when asked: automatic backups keep snapshots on
# the local disk while the backup disk is away.
sudo tmutil disable

# --- Apps ---
# Apps that update themselves, or that were installed before Homebrew, which
# cannot adopt them without App Management access: installed from their casks
# only when missing, rather than kept in the Brewfile.
while IFS=: read -r cask app; do
    if [ ! -d "/Applications/$app.app" ]; then
        echo "Installing $app..."
        brew install --cask "$cask"
    fi
done <<'APPS'
mullvad-vpn:Mullvad VPN
mullvad-browser:Mullvad Browser
chatgpt:ChatGPT
claude:Claude
discord:Discord
signal:Signal
gpg-suite:GPG Keychain
APPS

# Sparrow Wallet, installed only once verified as its author's.
"$ROLE_DIR/sparrow.sh"

# Tailscale's packets, tssh's among them, need an MTU of 1380 in Mullvad's
# tunnel: on its own, Mullvad lowers it below what they fit in. No IPv6.
mullvad tunnel set mtu 1380
mullvad tunnel set ipv6 off

mkdir -p ~/.config/zed ~/.local/bin
link "$ROLE_DIR/tssh" ~/.local/bin/tssh
link "$ROLE_DIR/tcopy" ~/.local/bin/tcopy
link "$ROLE_DIR/tscreen" ~/.local/bin/tscreen
link "$ROLE_DIR/trex" ~/.local/bin/trex
link "$ROLE_DIR/rex" ~/.local/bin/rex
link "$ROLE_DIR/cf" ~/.local/bin/cf
echo "Installing Cloudflare's cf..."
install_cf
git config --global core.editor "zed --wait"
# Cloned over HTTPS, as by bootstrap, dots pushes over SSH: the workstation
# makes every Git write.
if [ "$(git -C "$ROLE_DIR/.." remote get-url origin)" = https://github.com/nym21/dots.git ]; then
    git -C "$ROLE_DIR/.." remote set-url --push origin git@github.com:nym21/dots.git
fi
link "$ROLE_DIR/home/.config/zed/settings.json" ~/.config/zed/settings.json

# Rex keeps its settings in its preferences, which it rewrites, so they are
# written from pc/rex-settings, saved by pc/save.sh, rather than linked.
echo "Applying Rex settings..."
while read -r key type value; do
    case "$key" in
        ''|\#*) continue ;;
    esac
    defaults write com.superlogical.rex "$key" "-$type" "$value"
done < "$ROLE_DIR/rex-settings"

# The macOS settings pc/save.sh saved: Dock, Finder, keyboard, trackpad, and
# screenshots. The trackpad's apply at the next login.
echo "Applying macOS settings..."
while read -r domain key type value; do
    case "$domain" in
        ''|\#*) continue ;;
    esac
    defaults write "$domain" "$key" "-$type" "${value/#\~/$HOME}"
done < "$ROLE_DIR/macos-settings"
killall Dock Finder SystemUIServer 2>/dev/null || true

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
