#!/usr/bin/env bash
set -euo pipefail

# ship update: bring this Mac up to date and restart only what changed. It
# pulls dots and runs the version pulled, then updates Homebrew, Rust, and the
# listed Cargo tools; on a server also Rex and the workloads, within the
# mini's mode; macOS last, which restarts the Mac when it installs.
#
# ship fetch, on a server, runs it with --fetch: it readies the slow parts
# while the mini keeps serving, restarting nothing, so the update after only
# installs and restarts. fleet runs it on every server at once.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SERVER_DIR="$DOTS_DIR/server"
ROLE="$(cat "$HOME/.config/dots/role")"

if [ -z "${DOTS_PULLED:-}" ]; then
    echo "Updating dots..."
    git -C "$DOTS_DIR" pull -q --ff-only
    DOTS_PULLED=1 exec "$DOTS_DIR/shared/update.sh" "$@"
fi

source "$DOTS_DIR/shared/setup.sh"
link_commands

if [ "${1:-}" = --fetch ]; then
    # Bitview and the MCP server built in the mini's mode, and a macOS update
    # downloaded.
    "$SERVER_DIR/install.sh" --build
    "$DOTS_DIR/shared/macos-update.sh" --download
    exit 0
fi

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

echo "Updating Rust and the Cargo tools..."
rustup update
# Only the listed tools, installing any missing: ship install chooses the
# version a server's workloads run.
# shellcheck disable=SC2046
cargo install-update --allow-no-update --locked \
    $(cat "$DOTS_DIR/shared/cargo.txt" "$DOTS_DIR/$ROLE/cargo.txt" 2>/dev/null)

# What this Mac has that dots does not list, so the Macs stay alike: add it to
# a Brewfile or Cargo list, or uninstall it. Bitview's crates are a server's
# workloads, which ship install chooses.
unlisted="$(comm -23 \
    <({
        brew leaves --installed-on-request
        brew list --cask
        cargo install --list | awk '/^[[:alnum:]_-]+ v[^ ]+/ && $1 !~ /^bitview/ { print $1 }'
    } | sort -u) \
    <({
        sed -nE 's/^(brew|cask) "([^"]*)".*/\2/p' "$DOTS_DIR/shared/Brewfile" "$DOTS_DIR/$ROLE/Brewfile" |
            sed 's#.*/##'
        cat "$DOTS_DIR/shared/cargo.txt" "$DOTS_DIR/$ROLE/cargo.txt" 2>/dev/null
    } | sort -u) | paste -s -d ' ' -)"
if [ -n "$unlisted" ]; then
    echo "Installed but not in dots: $unlisted"
fi
if [ "$ROLE" = pc ]; then
    problem="$(backup_problem)"
    [ -z "$problem" ] || echo "Back up: $problem; connect the backup disk and run tmutil startbackup."
fi

case "$ROLE" in
    pc)
        merge_agent_settings
        update_cargo_hawk
        # Sparrow Wallet, updated only once verified as its author's.
        "$DOTS_DIR/pc/sparrow.sh" || echo "Sparrow was not updated; see above." >&2
        # Cloudflare's cf, which Bun installs and runs in place of Node.
        bun add -g --silent cf@latest

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

        # Within the mode this mini has, which fleet sets.
        "$SERVER_DIR/install.sh" || echo "Bitview is not installed; fleet update gives this mini its mode."

        # A running cloudflared keeps its old binary. The tunnels come back
        # once the node is ready.
        if [ "$(binary cloudflared)" != "$cloudflared_before" ] && pgrep -f server/tunnels.sh >/dev/null; then
            "$SERVER_DIR/workloads.sh" stop tunnels
            "$SERVER_DIR/workloads.sh" start
        fi
        ;;
esac

"$DOTS_DIR/shared/clean.sh"
"$DOTS_DIR/shared/macos-update.sh"

# Last, since a restart drops the connections over it, this update's own when
# it runs over SSH.
if [ "$ROLE" = server ] && [ "$(binary tailscaled)" != "$tailscaled_before" ]; then
    "$DOTS_DIR/shared/sudoers.sh"
    sudo launchctl kickstart -k system/com.local.tailscaled
fi
echo "Up to date."
