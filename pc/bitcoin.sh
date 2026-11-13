#!/usr/bin/env bash
set -euo pipefail

# This Mac's Bitcoin Core node, which its Bitview reads: a LaunchAgent that
# starts it at login and again whenever it exits. Its first sync runs with
# half the memory as UTXO cache and without relaying transactions, several
# times faster; once synced, it marks its data directory and stops, and
# launchd starts it again plain, as Bitview serves the mempool it then keeps.
#
#   bitcoin.sh       install the LaunchAgent
#   bitcoin.sh run   the node, which the LaunchAgent runs

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.local.bitcoind
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/bitcoind.log"
DOMAIN="gui/$(id -u)"
SYNCED="$HOME/Library/Application Support/Bitcoin/.dots-synced"

case "$#:${1:-}" in
    0:) ;;
    1:run)
        [ -e "$SYNCED" ] && exec bitcoind
        # The first sync's end: marked, then the node stops, to start again
        # plain. The watch ends with the node, which keeps this pid.
        node=$$
        (
            while sleep 300 && kill -0 "$node" 2>/dev/null; do
                if bitcoin-cli getblockchaininfo 2>/dev/null | grep -q '"initialblockdownload": false'; then
                    mkdir -p "$(dirname "$SYNCED")"
                    touch "$SYNCED"
                    bitcoin-cli stop
                    exit 0
                fi
            done
        ) &
        exec bitcoind -dbcache=$(($(sysctl -n hw.memsize) / 2097152)) -blocksonly=1
        ;;
    *)
        echo "Usage: $0 [run]" >&2
        exit 1
        ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PC_DIR/bitcoin.sh</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ExitTimeOut</key>
    <integer>900</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
if ! cmp -s "$tmp" "$PLIST" || ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    # A node stopping writes its cache to disk first, which can take minutes.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    for _ in {1..3600}; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.25
    done
    mv "$tmp" "$PLIST"
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Bitcoin Core runs, as a LaunchAgent; its log: $LOG"
fi
