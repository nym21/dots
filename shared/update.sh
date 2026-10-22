#!/usr/bin/env bash
set -euo pipefail

# dots update: bring this Mac up to date and restart only what changed. It
# pulls dots and runs the version pulled, then updates Homebrew, Rust, and the
# listed Cargo tools; on a server also Rex and the workloads, within the
# mini's mode; macOS last, which restarts the Mac when it installs.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SERVER_DIR="$DOTS_DIR/server"
ROLE="$(cat "$HOME/.config/dots/role")"

if [ -z "${DOTS_PULLED:-}" ]; then
    echo "Updating dots..."
    git -C "$DOTS_DIR" pull -q --ff-only
    DOTS_PULLED=1 exec "$DOTS_DIR/shared/update.sh" "$@"
fi

# Ask for sudo once and keep it, since the restarts and macOS come after
# builds that outlast its timeout.
sudo -v
while sleep 60; do sudo -n -v 2>/dev/null || exit; done &
keepalive=$!
trap 'kill "$keepalive" 2>/dev/null' EXIT

binary() {
    readlink -f "$(command -v "$1")" 2>/dev/null || true
}
cloudflared_before="$(binary cloudflared)"
tailscaled_before="$(binary tailscaled)"

echo "Updating Homebrew..."
brew update
# Install what the Brewfiles gained, then upgrade everything.
brew bundle install --file="$DOTS_DIR/shared/Brewfile"
brew bundle install --file="$DOTS_DIR/$ROLE/Brewfile"
brew upgrade
brew cleanup

echo "Updating Rust and the Cargo tools..."
rustup update
# Only the listed tools, installing any missing: dots install chooses the
# version a server's workloads run.
# shellcheck disable=SC2046
cargo install-update --allow-no-update --locked \
    $(cat "$DOTS_DIR/shared/cargo.txt" "$DOTS_DIR/$ROLE/cargo.txt" 2>/dev/null)

case "$ROLE" in
    pc)
        # Mullvad's split tunneling excludes cloudflared by its versioned Cellar
        # path, which an upgrade replaces. Move an existing exclusion to the
        # current binary.
        if command -v mullvad >/dev/null 2>&1 && command -v cloudflared >/dev/null 2>&1; then
            cloudflared_bin="$(binary cloudflared)"
            excluded="$(mullvad split-tunnel get | grep '/Cellar/cloudflared/.*/bin/cloudflared$' || true)"
            if [ -n "$excluded" ]; then
                while IFS= read -r path; do
                    [ "$path" = "$cloudflared_bin" ] || mullvad split-tunnel app remove "$path"
                done <<< "$excluded"
                if ! grep -Fxq "$cloudflared_bin" <<< "$excluded"; then
                    mullvad split-tunnel app add "$cloudflared_bin"
                fi
            fi
        fi
        # The Rex forwards keep tssh's Tailscale daemon, and its old binary,
        # running until they restart.
        if [ "$(binary tailscaled)" != "$tailscaled_before" ] && command -v trex >/dev/null 2>&1; then
            trex --stop >/dev/null
            trex
        fi
        ;;
    server)
        if [ -r "$SERVER_DIR/.rex-feed" ]; then
            "$SERVER_DIR/rex.sh" --yes
        fi

        source "$SERVER_DIR/crate.sh"
        mode="$(bitview_mode)"
        case "$mode" in
            '') echo "Bitview is not installed; set this mini's mode with dots install." ;;
            prod) "$SERVER_DIR/install.sh" ;;
            local) "$SERVER_DIR/install.sh" --local ;;
            *) "$SERVER_DIR/install.sh" "$mode" ;;
        esac

        # A running cloudflared keeps its old binary. The tunnels come back
        # once the node is ready.
        if [ "$(binary cloudflared)" != "$cloudflared_before" ] && pgrep -f server/tunnels.sh >/dev/null; then
            "$SERVER_DIR/workloads.sh" stop tunnels
            "$SERVER_DIR/workloads.sh" start
        fi
        ;;
esac

"$DOTS_DIR/shared/macos-update.sh"

# Last, since a restart drops the connections over it, this update's own when
# it runs over SSH.
if [ "$ROLE" = server ] && [ "$(binary tailscaled)" != "$tailscaled_before" ]; then
    sudo launchctl kickstart -k system/com.local.tailscaled
fi
echo "Up to date."
