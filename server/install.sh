#!/usr/bin/env bash

set -euo pipefail

# Run this mini in MODE, or in the mode it has: install Bitview and the MCP
# server in it, restart a workload whose build installed differs from the one
# it runs, and start whatever is not running. A run with nothing new leaves a
# running mini alone. fleet passes the versions to pin, bitviewd's and
# bitview_mcp's, so servers sharing a tunnel run the same one; without, it
# takes the newest. The first run asks for sudo, to have them start at boot.
# The tunnels restart too when they run an older cloudflared than the one
# installed, or tunnels.sh as it was before it changed, and the whole node when Bitcoin Core runs an older binary than the
# one Homebrew installed, so its upgrades take effect in fleet's order rather
# than at the next reboot.
#
# With --build, it only installs them, restarting nothing, as ship fetch does
# while the mini serves; with --restart, it only restarts and starts, as ship
# apply does after; with --pending, it only prints what --restart would
# restart, which fleet reads to know whether the mini's tunnels go down.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: $0 [--build] [release | prod | next | BRANCH | local [BITVIEWD_VERSION [MCP_VERSION]]]" >&2
    echo "       $0 --restart | --pending" >&2
    exit 1
}

step=all
case "${1:-}" in
    --build | --restart | --pending)
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
        echo "This mini has no mode yet; give one: release, prod, next, a branch, or local." >&2
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
# or commit of a branch, which a rebuild of the same one keeps; or one
# unrecorded, started before records were.
stale() {
    pgrep -x "$1" >/dev/null && [ "$(installed "$1")" != "$(cat "$RUNNING_DIR/$1" 2>/dev/null)" ]
}

# Whether NAME runs from another binary than the one installed, as after
# Homebrew upgraded it: a running process keeps the binary it started from.
binary_stale() {
    local pid current
    current="$(readlink -f "$(command -v "$1")")"
    for pid in $(pgrep -x "$1"); do
        [ "$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)" = "$current" ] || return 0
    done
    return 1
}

# Whether the tunnels workload started before tunnels.sh last changed, as a
# pull does: bash keeps running the script it started with.
script_stale() {
    local pid
    pid="$(pgrep -f 'server/tunnels\.sh$' | head -1)" || return 1
    [ "$(stat -f %m "$SERVER_DIR/tunnels.sh")" -gt \
        "$(LC_ALL=C date -j -f '%a %b %d %T %Y' "$(LC_ALL=C ps -o lstart= -p "$pid" | xargs)" +%s)" ]
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
if pgrep -qf 'server/tunnels\.sh$' && { binary_stale cloudflared || script_stale; }; then
    restart="$restart tunnels"
fi
# Everything else needs Bitcoin Core, so it all stops with it.
if binary_stale bitcoind; then
    restart="$restart tunnels mcp bitviewd bitcoind"
fi
if [ "$step" = pending ]; then
    # shellcheck disable=SC2086 # one line, the names apart
    echo $restart
    exit 0
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
