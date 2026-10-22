#!/usr/bin/env bash

set -euo pipefail

# Set this mini up in one mode, from install to boot: Bitview and the MCP
# server from crates.io (prod), a branch of the official repository (next), or
# the checkout in ~/Developer/mono (local), with Bitcoin Core and the
# Cloudflare tunnels. Each runs at boot as a LaunchDaemon under this user and
# restarts whenever it exits. They start in order by exiting until what they
# need is up: bitcoin.sh and bitview.sh wait for the external volume, and
# tunnels.sh for both servers. Running this again restarts only what changed,
# so a run with nothing new leaves a prod mini alone. Logs go to
# ~/Library/Logs and are trimmed hourly.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_USER="$(id -un)"
LOG_DIR="$HOME/Library/Logs"
# Logs above this size are moved to NAME.log.1, replacing the previous one.
LOG_LIMIT=$((100 * 1024 * 1024))

# name, process name, seconds to shut down before launchd kills it (empty for
# launchd's 20), command
SERVICES=(
    "bitcoind|bitcoind|600|$SERVER_DIR/bitcoin.sh"
    "bitviewd|bitviewd|600|$SERVER_DIR/bitview.sh"
    "bitview-mcp|bitview_mcp||$SERVER_DIR/mcp.sh"
    "tunnels|cloudflared||$SERVER_DIR/tunnels.sh"
)

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local]" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

source "$SERVER_DIR/crate.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checksum() {
    shasum "$HOME/.cargo/bin/$1" 2>/dev/null || true
}

# --- Bitview and the MCP server ---

bitviewd_before="$(checksum bitviewd)"
mcp_before="$(checksum bitview_mcp)"

rustup update
install_crate bitviewd "$@"
install_crate bitview_mcp "$@"

# Daemons to restart on a new binary. The tunnels follow Bitview, whose install
# sets the mode.
changed=' '
if [ "$(checksum bitviewd)" != "$bitviewd_before" ]; then
    changed="$changed bitviewd tunnels "
fi
if [ "$(checksum bitview_mcp)" != "$mcp_before" ]; then
    changed="$changed bitview-mcp "
fi

# --- Daemons ---

started=' '

plist_header() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$1</string>

    <key>UserName</key>
    <string>$SERVER_USER</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>USER</key>
        <string>$SERVER_USER</string>
        <key>PATH</key>
        <string>$HOME/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>$HOME</string>
PLIST
}

# Install or update the daemon $1 from the plist $2, restarting it only when
# the plist changed.
install_daemon() {
    local label="$1" plist="$2" dest="/Library/LaunchDaemons/$1.plist"

    plutil -lint "$plist" >/dev/null
    if cmp -s "$plist" "$dest" && sudo launchctl print "system/$label" >/dev/null 2>&1; then
        echo "$label: up to date"
        return 0
    fi
    if sudo launchctl print "system/$label" >/dev/null 2>&1; then
        echo "$label: stopping to update..."
        sudo launchctl bootout "system/$label" || true
        # bootout returns before the program exits and launchd removes the
        # service, and an immediate bootstrap then fails with an I/O error.
        while sudo launchctl print "system/$label" >/dev/null 2>&1; do
            sleep 1
        done
    fi
    sudo install -o root -g wheel -m 644 "$plist" "$dest"
    sudo launchctl enable "system/$label"
    sudo launchctl bootstrap system "$dest"
    started="$started ${label#com.local.} "
    echo "$label: started"
}

sudo -v
mkdir -p "$LOG_DIR"

for service in "${SERVICES[@]}"; do
    IFS='|' read -r name process exit_timeout command <<< "$service"
    label="com.local.$name"
    log="$LOG_DIR/$name.log"

    # A copy started by hand, in a Rex pane for example, would hold the same
    # data and ports as the daemon.
    if ! sudo launchctl print "system/$label" >/dev/null 2>&1 && pgrep -x "$process" >/dev/null; then
        echo "$label: skipped, $process already runs outside launchd; stop it, then run this again." >&2
        continue
    fi

    # Create the log as this user, so launchd appends to a file it can trim.
    touch "$log"

    {
        plist_header "$label"
        echo
        echo "    <key>ProgramArguments</key>"
        echo "    <array>"
        for argument in $command; do
            echo "        <string>$argument</string>"
        done
        echo "    </array>"
        if [ -n "$exit_timeout" ]; then
            echo
            echo "    <key>ExitTimeOut</key>"
            echo "    <integer>$exit_timeout</integer>"
        fi
        cat <<PLIST

    <key>StandardOutPath</key>
    <string>$log</string>
    <key>StandardErrorPath</key>
    <string>$log</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST
    } > "$WORK/$label.plist"

    install_daemon "$label" "$WORK/$label.plist"
done

# launchd appends to each log, so truncating it in place is safe.
LOGS=''
for service in "${SERVICES[@]}"; do
    LOGS="$LOGS $LOG_DIR/${service%%|*}.log"
done
{
    plist_header com.local.trim-logs
    cat <<PLIST

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>
for log in$LOGS; do
    if [ "\$(/usr/bin/stat -f %z "\$log" 2>/dev/null || echo 0)" -gt $LOG_LIMIT ]; then
        /bin/cp "\$log" "\$log.1" &amp;&amp; : > "\$log"
    fi
done
exit 0
        </string>
    </array>

    <key>StartInterval</key>
    <integer>3600</integer>
</dict>
</plist>
PLIST
} > "$WORK/com.local.trim-logs.plist"

install_daemon com.local.trim-logs "$WORK/com.local.trim-logs.plist"

# Restart the daemons still running an older binary; one installed above
# already started on the new one. TERM lets each shut down cleanly, and
# launchd starts it again.
for name in bitviewd bitview-mcp tunnels; do
    case "$changed" in
        *" $name "*) ;;
        *) continue ;;
    esac
    case "$started" in
        *" $name "*) continue ;;
    esac
    sudo launchctl print "system/com.local.$name" >/dev/null 2>&1 || continue
    sudo launchctl kill TERM "system/com.local.$name"
    echo "com.local.$name: restarting on the new binary"
done
