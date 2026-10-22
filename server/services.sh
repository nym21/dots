#!/usr/bin/env bash
set -euo pipefail

# Run Bitcoin Core, Bitview, the MCP server, and the Cloudflare tunnels at boot
# as LaunchDaemons under this user, each restarted whenever it exits. They
# start in order by exiting until what they need is up: bitcoin.sh and
# bitview.sh wait for the external volume, and tunnels.sh for the three
# backends. install.sh chooses which version runs; this only installs the
# daemons.
# Logs go to ~/Library/Logs and are trimmed hourly.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_USER="$(id -un)"
LOG_DIR="$HOME/Library/Logs"
# Logs above this size are moved to NAME.log.1, replacing the previous one.
LOG_LIMIT=$((100 * 1024 * 1024))

# name, process name, command
SERVICES=(
    "bitcoind|bitcoind|$SERVER_DIR/bitcoin.sh"
    "bitviewd|bitviewd|$SERVER_DIR/bitview.sh"
    "bitview-mcp|bitview_mcp|$SERVER_DIR/mcp.sh"
    "tunnels|cloudflared|$SERVER_DIR/tunnels.sh"
)

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
        sudo launchctl bootout "system/$label"
    fi
    sudo install -o root -g wheel -m 644 "$plist" "$dest"
    sudo launchctl enable "system/$label"
    sudo launchctl bootstrap system "$dest"
    echo "$label: started"
}

sudo -v
mkdir -p "$LOG_DIR"

for service in "${SERVICES[@]}"; do
    IFS='|' read -r name process command <<< "$service"
    label="com.local.$name"
    log="$LOG_DIR/$name.log"

    # A copy started by hand, in a Rex pane for example, would hold the same data
    # and ports as the daemon.
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

for binary in bitviewd bitview_mcp; do
    if ! command -v "$binary" >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/$binary" ]; then
        echo "Warning: $binary is not installed; run ./server/install.sh." >&2
    fi
done
