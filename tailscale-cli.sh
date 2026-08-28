#!/usr/bin/env bash
set -euo pipefail

PLIST_DEST="/Library/LaunchDaemons/com.local.tailscaled.plist"
SERVICE="system/com.local.tailscaled"
TAILSCALE="/opt/homebrew/opt/tailscale/bin/tailscale"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Install Homebrew first." >&2
    exit 1
fi

if brew list --cask tailscale-app >/dev/null 2>&1 || [ -d /Applications/Tailscale.app ] || pgrep -f io.tailscale.ipn.macsys.network-extension >/dev/null 2>&1; then
    echo "Remove the Tailscale GUI app and reboot before installing tailscaled." >&2
    exit 1
fi

brew install tailscale

PLIST_TMP="$(mktemp)"
trap 'rm -f "$PLIST_TMP"' EXIT

cat > "$PLIST_TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.tailscaled</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/opt/tailscale/bin/tailscaled</string>
        <string>--no-logs-no-support</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_TMP" >/dev/null

if sudo launchctl print "$SERVICE" >/dev/null 2>&1; then
    sudo launchctl bootout "$SERVICE"
fi

sudo install -o root -g wheel -m 644 "$PLIST_TMP" "$PLIST_DEST"
sudo launchctl enable "$SERVICE"
sudo launchctl bootstrap system "$PLIST_DEST"

for _ in {1..40}; do
    [ -S /var/run/tailscaled.socket ] && break
    sleep 0.25
done

if [ ! -S /var/run/tailscaled.socket ]; then
    echo "tailscaled did not create its socket." >&2
    sudo launchctl print "$SERVICE" >&2
    exit 1
fi

sudo "$TAILSCALE" up
sudo "$TAILSCALE" status
