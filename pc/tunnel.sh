#!/usr/bin/env bash
set -euo pipefail

# This Mac's own tunnel, local, which serves its Bitview, built from
# ~/Developer/mono, at local.bitview.space: a LaunchAgent that starts it at
# login and again whenever it exits. ship update runs this after upgrading,
# and fleet auto hourly, for an upgrade made otherwise, so a new cloudflared
# takes over on its own: Mullvad's exclusion first, then the tunnel restarts
# onto it. While the tunnel runs the cloudflared installed, nothing changes.
#
#   tunnel.sh       install the LaunchAgent, restart the tunnel onto a new
#                   cloudflared, or stop it when pc/.tunnels lacks its token
#                   or fleet.conf gives it to a server, as two machines on one
#                   tunnel would serve two versions
#   tunnel.sh run   the tunnel, which the LaunchAgent runs

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.local.tunnel
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/local-tunnel.log"
DOMAIN="gui/$(id -u)"

token() {
    awk '$1 == "local" { print $2 }' "$PC_DIR/.tunnels" 2>/dev/null || true
}

case "$#:${1:-}" in
    0:) ;;
    1:run)
        # However it started, excluded from Mullvad before it connects, and
        # the binary it ran before no longer.
        "$PC_DIR/split-tunnel.sh" || true
        token="$(token)"
        if [ -z "$token" ]; then
            echo "pc/.tunnels has no token for local." >&2
            exit 1
        fi
        TUNNEL_TOKEN="$token" exec cloudflared tunnel --no-autoupdate run
        ;;
    *)
        echo "Usage: $0 [run]" >&2
        exit 1
        ;;
esac

# Mullvad's exclusion, onto the cloudflared installed, for any cloudflared of
# this Mac's, and before the tunnel restarts onto it.
"$PC_DIR/split-tunnel.sh"

stop() {
    [ -e "$PLIST" ] || return 0
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "The local tunnel is stopped: $1."
}
if [ -z "$(token)" ]; then
    stop "pc/.tunnels has no token for it"
    exit 0
fi
if awk '!/^#/ { for (i = 3; i <= NF; i++) if ($i == "local") found = 1 } END { exit !found }' "$PC_DIR/fleet.conf"; then
    stop "fleet.conf gives it to a server"
    exit 0
fi

# Its log keeps the last 5 to 10 MB, cut in place, as launchd writes to the
# file it opened.
if [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    tail -c 5242880 "$LOG" > "$LOG.new" && cat "$LOG.new" > "$LOG"
    rm -f "$LOG.new"
fi

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
        <string>$PC_DIR/tunnel.sh</string>
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
    <integer>10</integer>
</dict>
</plist>
PLIST
if ! cmp -s "$tmp" "$PLIST" || ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    # bootout can return before launchd has removed it, and a bootstrap then
    # fails.
    for _ in {1..40}; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.25
    done
    mv "$tmp" "$PLIST"
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "The local tunnel runs, as a LaunchAgent; its log: $LOG"
    exit 0
fi

# Onto the cloudflared installed, once the tunnel runs another, as after an
# upgrade: launchd starts it again at once. Between its start and cloudflared,
# it runs no cloudflared, which is left alone.
cloudflared_bin="$(readlink -f "$(command -v cloudflared)" 2>/dev/null)" || exit 0
pid="$(launchctl print "$DOMAIN/$LABEL" | awk '$1 == "pid" { print $3; exit }')"
[ -n "$pid" ] || exit 0
running="$(lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" { print $NF; exit }')"
case "$running" in
    "$cloudflared_bin" | '') ;;
    */Cellar/cloudflared/*/bin/cloudflared)
        echo "The local tunnel restarts onto the cloudflared installed."
        launchctl kickstart -k "$DOMAIN/$LABEL"
        ;;
esac
