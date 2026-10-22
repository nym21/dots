#!/usr/bin/env bash

set -euo pipefail

# Set this mini's mode and run it: install Bitview and the MCP server from
# crates.io (prod), a branch of the official repository (next), or the
# checkout in ~/Developer/mono (local), restart the workloads that changed
# version, and start whatever is not running. A run with nothing new leaves a
# running mini alone. The first run asks for sudo, to have them start at boot.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local]" >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

# The Rex server comes back at boot on its own, the workloads with this daemon.
# It is only installed, for the next boot: loading it now would start them
# twice at once. Done first, so nothing is stopped while sudo asks.
BOOT_PLIST=/Library/LaunchDaemons/com.local.workloads.plist
plist="$(mktemp)"
trap 'rm -f "$plist"' EXIT
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.workloads</string>

    <key>UserName</key>
    <string>$(id -un)</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SERVER_DIR/workloads.sh</string>
        <string>boot</string>
    </array>

    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/workloads-boot.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/workloads-boot.log</string>

    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null
if ! cmp -s "$plist" "$BOOT_PLIST"; then
    echo "Installing com.local.workloads, which starts the workloads at boot..."
    sudo install -o root -g wheel -m 644 "$plist" "$BOOT_PLIST"
    sudo launchctl enable system/com.local.workloads
fi

# What decides a restart: the version, or the commit of a branch. A rebuild
# of the same one, as cargo does after a Rust update, needs none. A local build
# shows no change there, so any new binary counts.
installed() {
    if [ "${1:-}" = --local ]; then
        shasum "$HOME/.cargo/bin/$2" 2>/dev/null || true
    else
        cargo install --list | awk -v crate="$2" '$1 == crate { print; exit }'
    fi
}

bitviewd_before="$(installed "${1:-}" bitviewd)"
mcp_before="$(installed "${1:-}" bitview_mcp)"

rustup update
install_crate bitviewd "$@"
install_crate bitview_mcp "$@"

# The tunnels follow Bitview, whose install sets the mode, and stop before a
# server restarts so no traffic reaches it meanwhile.
restart=''
if [ "$(installed "${1:-}" bitviewd)" != "$bitviewd_before" ]; then
    restart="$restart tunnels bitviewd"
fi
if [ "$(installed "${1:-}" bitview_mcp)" != "$mcp_before" ]; then
    restart="$restart tunnels mcp"
fi
if [ -n "$restart" ]; then
    # shellcheck disable=SC2086
    "$SERVER_DIR/workloads.sh" stop $restart
fi

"$SERVER_DIR/workloads.sh" start
