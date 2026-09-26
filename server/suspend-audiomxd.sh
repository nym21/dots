#!/usr/bin/env bash
set -euo pipefail

PLIST_DEST="/Library/LaunchDaemons/com.local.suspend-audiomxd.plist"
SERVICE="system/com.local.suspend-audiomxd"

PLIST_TMP="$(mktemp)"
trap 'rm -f "$PLIST_TMP"' EXIT

cat > "$PLIST_TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.suspend-audiomxd</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>
attempt=0
while [ "$attempt" -lt 120 ]; do
    if /usr/bin/killall -STOP audiomxd 2>/dev/null; then
        exit 0
    fi
    /bin/sleep 1
    attempt=$((attempt + 1))
done
exec /usr/bin/killall -STOP audiomxd
        </string>
    </array>

    <key>RunAtLoad</key>
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

echo "Installed: suspend audiomxd once now and after each boot."
echo "Startup wait is limited to two minutes; there is no periodic retry after that."
