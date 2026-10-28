#!/usr/bin/env bash
set -euo pipefail

# ship update: bring this Mac up to date and restart only what changed. It
# pulls dots and runs the version pulled, then updates Homebrew, Rust, and the
# listed Cargo tools; on a server also Rex and the workloads, within the
# mini's mode; macOS last, which restarts the Mac when it installs.
#
# On a server it is two halves, which fleet runs apart: every server readies at
# once while all serve, and only then does each restart, in turn, for seconds.
#
#   update.sh --fetch     ship fetch: ready everything, restarting nothing:
#                         Homebrew, Rust, the Cargo tools, Rex's newest build,
#                         Bitview and the MCP server in the mini's mode, the
#                         cleanup, Apple's updates but macOS, and macOS's
#                         downloaded
#   update.sh --apply     ship apply: restart only what runs something other
#                         than what is installed, and start what is not running

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SERVER_DIR="$DOTS_DIR/server"
ROLE="$(cat "$HOME/.config/dots/role")"

step=all
case "$#:${1:-}" in
    0:) ;;
    1:--fetch) step=fetch ;;
    1:--apply) step=apply ;;
    *)
        echo "Usage: $0 [--fetch | --apply]" >&2
        exit 1
        ;;
esac

# Restart what runs something other than what is installed, each for the
# seconds it takes, and start what is not running: the Rex server, which
# restarts the workloads too; Bitview and the MCP server, with the tunnels; and
# the tunnels, for a new cloudflared or other tokens.
apply() {
    if [ -r "$SERVER_DIR/.rex-feed" ] && [ -n "$("$SERVER_DIR/rex.sh" --pending)" ]; then
        "$SERVER_DIR/rex.sh" --yes
    fi
    "$SERVER_DIR/install.sh" --restart || echo "Bitview is not installed; fleet update gives this mini its mode."
}

# Last, since a restart drops the connections over it, this update's own when
# it runs over SSH: the Tailscale daemon onto Homebrew's tailscaled, as root's
# copy, which needs root, so a terminal; fleet update does it otherwise.
update_tailscaled() {
    "$SERVER_DIR/tailscale.sh" --check && return 0
    if [ -t 0 ]; then
        "$SERVER_DIR/tailscale.sh" --update
    else
        echo "Tailscale's daemon is not on Homebrew's tailscaled; fleet update moves it."
    fi
}

if [ "$step" = apply ]; then
    apply
    echo "Applied."
    exit 0
fi

if [ -z "${DOTS_PULLED:-}" ]; then
    echo "Updating dots..."
    git -C "$DOTS_DIR" pull -q --ff-only
    DOTS_PULLED=1 exec "$DOTS_DIR/shared/update.sh" "$@"
fi

source "$DOTS_DIR/shared/setup.sh"
link_commands

binary() {
    readlink -f "$(command -v "$1")" 2>/dev/null || true
}
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
# The workstation backs up whenever its backup disk is in; without it, Time
# Machine is left alone, and only an overdue backup is mentioned.
if [ "$ROLE" = pc ]; then
    name="$(backup_name)"
    if [ -n "$name" ] && [ -n "$(backup_volume "$name")" ]; then
        "$DOTS_DIR/pc/backup.sh" || echo "The backup did not complete; see above." >&2
    else
        problem="$(backup_problem)"
        [ -z "$problem" ] || echo "Back up: $problem; put the backup disk in and run ship backup."
    fi
fi

case "$ROLE" in
    pc)
        merge_agent_settings
        update_cargo_hawk
        install_fleet_auto
        # Sparrow Wallet, updated only once verified as its author's.
        "$DOTS_DIR/pc/sparrow.sh" || echo "Sparrow was not updated; see above." >&2
        install_cf

        # Mullvad's exclusion of cloudflared, and this Mac's tunnel, onto the
        # version just upgraded to.
        "$DOTS_DIR/pc/tunnel.sh" || echo "This Mac's tunnel was not moved onto the cloudflared installed; see above." >&2
        # The Rex forwards keep tssh's Tailscale daemon, and its old binary,
        # running until they restart.
        if [ "$(binary tailscaled)" != "$tailscaled_before" ] && command -v trex >/dev/null 2>&1; then
            trex --stop >/dev/null
            trex
        fi
        ;;
    server)
        if [ -r "$SERVER_DIR/.rex-feed" ]; then
            "$SERVER_DIR/rex.sh" --download
        fi
        # Within the mode this mini has, which fleet sets.
        if ! "$SERVER_DIR/install.sh" --build; then
            [ "$step" = all ] || exit 1
            echo "Bitview is not installed; fleet update gives this mini its mode."
        fi
        ;;
esac

"$DOTS_DIR/shared/clean.sh"
if [ "$step" = fetch ]; then
    "$DOTS_DIR/shared/macos-update.sh" --download
    exit 0
fi
[ "$ROLE" != server ] || apply
"$DOTS_DIR/shared/macos-update.sh"
[ "$ROLE" != server ] || update_tailscaled
echo "Up to date."
