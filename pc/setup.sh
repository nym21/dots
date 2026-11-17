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

# A second Claude account, in its own config dir: only its login and session
# state are its own, and the rest is linked to the first account's, so both
# share rules, settings, skills, plugins, memory and transcripts. Claude Code
# writes settings through the link, keeping it. Account 1 keeps the default
# dir: CLAUDE_CONFIG_DIR set, even to ~/.claude, names another keychain item.
mkdir -p ~/.claude-2
for name in CLAUDE.md settings.json skills agents plugins projects; do
    link ~/.claude/"$name" ~/.claude-2/"$name"
done
# T3 runs it as its own provider instance, "Claude 2"; T3 reloads the file
# when it changes, so it is written only when the instance differs.
t3_settings=~/.t3/userdata/settings.json
if [ -d ~/.t3/userdata ]; then
    [ -s "$t3_settings" ] || echo '{}' > "$t3_settings"
    tmp="$(mktemp)"
    jq --arg dir ~/.claude-2 '.providerInstances.claudeAgent_account2 += {
        driver: "claudeAgent", displayName: "Claude 2", enabled: true,
        environment: [{name: "CLAUDE_CONFIG_DIR", value: $dir, sensitive: false}]
    }' "$t3_settings" > "$tmp"
    if [ "$(jq -S . "$tmp")" != "$(jq -S . "$t3_settings")" ]; then
        echo "Adding Claude 2 to T3..."
        mv "$tmp" "$t3_settings"
    else
        rm "$tmp"
    fi
fi

# This Mac never sleeps, on battery or with its lid closed too, so T3 and its
# agents, fleet auto, the node and the tunnels keep running; no deep sleep or
# Power Nap wakes either. Its display stays on with no screen saver, so the
# screen never locks, which iPhone Mirroring's automatic sign-in needs: with
# the lid closed, an attached display (an HDMI dummy) keeps it on.
sudo pmset -a sleep 0 displaysleep 0 disablesleep 1 standby 0 powernap 0
defaults -currentHost write com.apple.screensaver idleTime -int 0

# --- Mullvad, for Transmission alone ---
# The rest of this Mac goes direct. The Mullvad app tunnelled all of it, and
# under build load its userspace split-tunnel path stalled until the Mac had
# no internet (2026-11-17), so no Mullvad app: a WireGuard tunnel of this
# Mac's own carries only Transmission's address (pc/transmission-vpn says how).
# A LaunchDaemon brings it up at boot and keeps it alive; its device is
# registered by hand, once, as it takes the account number.
echo "Installing Transmission's tunnel..."
sudo mkdir -p /usr/local/sbin
sudo install -o root -g wheel -m 755 "$ROLE_DIR/transmission-vpn" /usr/local/sbin/transmission-vpn
sudo install -o root -g wheel -m 644 "$ROLE_DIR/com.local.transmission-vpn-tunnel.plist" /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.transmission-vpn-tunnel.plist 2>/dev/null ||
    sudo launchctl kickstart system/com.local.transmission-vpn-tunnel

# This Mac's own node, which its Bitview reads.
"$ROLE_DIR/bitcoin.sh"

# The home video server, a private repo: Transmission through its tunnel, files
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

missing="$(missing_steps)"
echo
echo "PC setup complete."
if [ -n "$missing" ]; then
    echo "Remaining:"
    sed 's/^/  - /' <<< "$missing"
fi
