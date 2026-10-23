#!/usr/bin/env bash

set -euo pipefail

# Run this mini in MODE, or in the mode it has: install Bitview and the MCP
# server in it, restart a workload whose build installed differs from the one
# it runs, and start whatever is not running. A run with nothing new leaves a
# running mini alone. fleet passes the versions to pin, bitviewd's and
# bitview_mcp's, so servers sharing a tunnel run the same one; without, it
# takes the newest. The first run asks for sudo, to have them start at boot.
# The tunnels restart too when they run an older cloudflared than the one
# installed, or other tokens than fleet gave.
#
# With --build, it only installs them, restarting nothing, as ship fetch does
# while the mini serves; with --restart, it only restarts and starts, as ship
# apply does after.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: $0 [--build] [prod | next | BRANCH | local [BITVIEWD_VERSION [MCP_VERSION]]]" >&2
    echo "       $0 --restart" >&2
    exit 1
}

step=all
case "${1:-}" in
    --build | --restart)
        step="${1#--}"
        shift
        ;;
esac
[ "$#" -le 3 ] || usage
[ "$step" = all ] || [ "$step" = build ] || [ "$#" -eq 0 ] || usage

source "$SERVER_DIR/crate.sh"

if [ "$step" = all ] || [ "$step" = build ]; then
    if [ "$#" -gt 0 ]; then
        mode="$1" pin="${2:-}" mcp_pin="${3:-${2:-}}"
    elif [ -r "$MODE_FILE" ]; then
        read -r mode pin mcp_pin < "$MODE_FILE" || true
        mcp_pin="${mcp_pin:-$pin}"
    else
        mode="$(bitview_mode)" pin='' mcp_pin=''
    fi
    if [ -z "${mode:-}" ]; then
        echo "This mini has no mode yet; give one: prod, next, a branch, or local." >&2
        exit 1
    fi

    rustup update
    install_crate bitviewd "$mode" "$pin"
    install_crate bitview_mcp "$mode" "$mcp_pin"
    mkdir -p "$(dirname "$MODE_FILE")"
    echo "$mode${pin:+ $pin}${pin:+ $mcp_pin}" > "$MODE_FILE"
fi
[ "$step" != build ] || exit 0

# Whether CRATE's binary runs, but not the build installed: another version,
# or commit of a branch, which a rebuild of the same one, as cargo does after a
# Rust update, keeps; or one unrecorded, started before records were.
stale() {
    pgrep -x "$1" >/dev/null && [ "$(installed "$1")" != "$(cat "$RUNNING_DIR/$1" 2>/dev/null)" ]
}

# Whether the tunnels run on other tokens than fleet gave, as their supervisor
# recorded at their start, or a cloudflared other than the one installed.
tunnels_stale() {
    local pid current
    pgrep -f server/tunnels.sh >/dev/null || return 1
    [ "$(tokens_digest)" = "$(cat "$RUNNING_DIR/tunnels" 2>/dev/null)" ] || return 0
    current="$(readlink -f "$(command -v cloudflared)")"
    for pid in $(pgrep -x cloudflared); do
        [ "$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)" = "$current" ] || return 0
    done
    return 1
}

# The tunnels stop before a server restarts, so no traffic reaches it
# meanwhile.
restart=''
if stale bitviewd; then
    restart="$restart tunnels bitviewd"
fi
if stale bitview_mcp; then
    restart="$restart tunnels mcp"
fi
if tunnels_stale; then
    restart="$restart tunnels"
fi

# The Rex server comes back at boot on its own, the workloads with this daemon.
# It is only installed, for the next boot: loading it now would start them
# twice at once. Done before any restart, so nothing is stopped while sudo asks.
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

if [ -n "$restart" ]; then
    # shellcheck disable=SC2086
    "$SERVER_DIR/workloads.sh" stop $restart
fi

"$SERVER_DIR/workloads.sh" start
