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

# --- Agents ---
echo "Merging Codex and Claude Code settings..."
merge_agent_settings

# --- Mullvad ---
# Mullvad VPN updates itself, so it is installed once rather than kept in the
# Brewfile. Tailscale's packets, tssh's among them, need an MTU of 1380 in its
# tunnel: on its own, Mullvad lowers it below what they fit in. No IPv6.
if [ ! -d "/Applications/Mullvad VPN.app" ]; then
    echo "Installing Mullvad VPN..."
    brew install --cask mullvad-vpn
fi
mullvad tunnel set mtu 1380
mullvad tunnel set ipv6 off

mkdir -p ~/.config/zed ~/.local/bin
link "$ROLE_DIR/tssh" ~/.local/bin/tssh
link "$ROLE_DIR/tcopy" ~/.local/bin/tcopy
link "$ROLE_DIR/tscreen" ~/.local/bin/tscreen
link "$ROLE_DIR/trex" ~/.local/bin/trex
link "$ROLE_DIR/cf" ~/.local/bin/cf
echo "Installing Cloudflare's cf..."
bun add -g --silent cf@latest
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

# What only you can do, listed while it is still missing.
remaining=()
[ "$(defaults read .GlobalPreferences LDMGlobalEnabled 2>/dev/null)" = 1 ] ||
    remaining+=("Turn on Lockdown Mode: System Settings > Privacy & Security > Lockdown Mode, then restart.")
mullvad account get 2>/dev/null | grep -q '^Mullvad account:' ||
    remaining+=("Log in to Mullvad VPN: mullvad account login.")
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 |
    grep -q 'successfully authenticated' ||
    remaining+=("Give GitHub an SSH key: ssh-keygen -t ed25519, then add ~/.ssh/id_ed25519.pub at https://github.com/settings/keys.")
cf auth whoami 2>/dev/null | jq -e .authenticated >/dev/null 2>&1 ||
    remaining+=("Log in to Cloudflare: cf auth login.")
[ "$(tssh --tailscale status --json 2>/dev/null | jq -r .BackendState)" = Running ] ||
    remaining+=("Log in to the tailnet: tssh mini@SERVER once, and open the link it prints.")
ls -d /Applications/Rex*.app >/dev/null 2>&1 ||
    remaining+=("Install the Rex app.")
# From the App Store, which Homebrew cannot check without Spotlight's index.
for app in "AdGuard for Safari" "Blackmagic Disk Speed Test" Developer "Numbers Creator Studio" \
    "Pages Creator Studio" Xcode; do
    [ -d "/Applications/$app.app" ] || remaining+=("Install $app from the App Store.")
done
hosts="$(rex hosts list --json 2>/dev/null | jq -r '.hosts[]?.host.label' 2>/dev/null || true)"
for server in $(awk '!/^#/ && NF { print $1 }' "$ROLE_DIR/fleet.conf"); do
    if ! grep -qx "$server" <<< "$hosts"; then
        remaining+=("Run trex, which gives the Rex app the servers' Rex.")
        break
    fi
done

echo
echo "PC setup complete."
if [ "${#remaining[@]}" -gt 0 ]; then
    echo "Remaining:"
    printf '  - %s\n' "${remaining[@]}"
fi
