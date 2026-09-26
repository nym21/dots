#!/usr/bin/env bash
set -e

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

ROLE=server
source "$(dirname "$0")/../shared/setup.sh"

SERVER_USER="$(id -un)"

if ! id -Gn "$SERVER_USER" | tr ' ' '\n' | grep -qx admin; then
    echo "Server user '$SERVER_USER' must be an administrator for full-volume file sharing." >&2
    exit 1
fi

sudo -v
# Probe an actual read: file mode checks do not establish Full Disk Access.
# sudo handles Unix permissions; macOS privacy checks still apply.
if ! sudo /bin/dd if="/Library/Application Support/com.apple.TCC/TCC.db" \
    of=/dev/null bs=1 count=1 >/dev/null 2>&1; then
    echo "Cannot verify Full Disk Access. Server setup has not started." >&2
    echo "Local terminal: System Settings > Privacy & Security > Full Disk Access." >&2
    echo "  Enable your terminal app, then quit and reopen it." >&2
    echo "SSH: System Settings > General > Sharing > Remote Login > Info." >&2
    echo "  Enable Allow full disk access for remote users, then reconnect." >&2
    exit 1
fi

shared_setup

# --- Headless macOS system ---
NETWORK_SERVICES=("Ethernet" "USB 10/100/1G/2.5G LAN")
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"

install_sysctl_conf() {
    local tmp
    tmp="$(mktemp)"

    {
        if [ -f "$SYSCTL_CONF" ]; then
            awk '
                $0 == "# dots server sysctl begin" { skip = 1; next }
                $0 == "# dots server sysctl end" { skip = 0; next }
                !skip { print }
            ' "$SYSCTL_CONF"
        fi

        echo "# dots server sysctl begin"
        echo "kern.ipc.somaxconn=2048"
        echo "# dots server sysctl end"
    } > "$tmp"

    sudo install -o root -g wheel -m 644 "$tmp" "$SYSCTL_CONF"
    rm -f "$tmp"
}

# Persistent TCP tuning. /etc/sysctl.conf is read during multi-user boot.
install_sysctl_conf
sudo sysctl -w kern.ipc.somaxconn=2048

# Cloudflare DNS on the wired services.
for service in "${NETWORK_SERVICES[@]}"; do
    if networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$service"; then
        sudo networksetup -setdnsservers "$service" "${DNS_SERVERS[@]}"
    else
        echo "Skipping DNS: network service '$service' was not found." >&2
    fi
done

# Disable Spotlight indexing.
sudo mdutil -a -i off
mdutil -a -s

# Keep the machine reachable while allowing the display to sleep.
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1

# Disable unused sharing features through their supported controls.
sudo systemsetup -setremoteappleevents off
CONTENT_CACHE_STATUS="$(AssetCacheManagerUtil -j status)"
CONTENT_CACHE_ACTIVATED="$(plutil -extract result.Activated raw -expect bool - <<< "$CONTENT_CACHE_STATUS")"
if [ "$CONTENT_CACHE_ACTIVATED" = true ]; then
    sudo AssetCacheManagerUtil deactivate
else
    echo "Content Caching is already disabled."
fi
sudo cupsctl -h /private/var/run/cupsd --no-share-printers

# Mount external disks without requiring a GUI user login.
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true

# Every non-system volume attached to this server is a server-owned data disk.
# Claim only the volume root; preserve ownership within existing contents.
for volume in /Volumes/*; do
    [ -d "$volume" ] && [ ! -L "$volume" ] || continue
    [ "$(basename "$volume")" = "Macintosh HD" ] && continue
    echo "Setting ownership of '$volume' to $SERVER_USER:staff..."
    sudo chown "$SERVER_USER:staff" "$volume"
done

# Normal OpenSSH over Tailscale. Tailscale provides private network access;
# sshd still handles authentication.
sudo systemsetup -setremotelogin on

# Keep Screen Sharing and SMB available on demand, without restarting
# active connections when setup is rerun.
sudo sysadminctl -smbGuestAccess off
for service in com.apple.screensharing com.apple.smbd; do
    sudo launchctl enable "system/$service"
    if ! sudo launchctl print "system/$service" >/dev/null 2>&1; then
        sudo launchctl bootstrap system "/System/Library/LaunchDaemons/$service.plist"
    fi
done

# Disable unused wireless radios. Refuse to turn off the server's active
# network path so remote setup cannot strand the machine.
WIFI_DEVICE="$(
    networksetup -listallhardwareports |
        awk '
            $0 == "Hardware Port: Wi-Fi" || $0 == "Hardware Port: AirPort" {
                getline
                sub(/^Device: /, "")
                print
                exit
            }
        '
)"
if [ -n "$WIFI_DEVICE" ]; then
    DEFAULT_ROUTE="$(route -n get default)"
    DEFAULT_INTERFACE="$(awk '$1 == "interface:" { print $2; exit }' <<< "$DEFAULT_ROUTE")"
    if [ -z "$DEFAULT_INTERFACE" ] || [ "$DEFAULT_INTERFACE" = "$WIFI_DEVICE" ]; then
        echo "Refusing to disable Wi-Fi: no other default network interface was confirmed." >&2
        echo "Connect and verify Ethernet, then run server setup again." >&2
        exit 1
    fi

    sudo networksetup -setairportpower "$WIFI_DEVICE" off
    echo "Wi-Fi: $(networksetup -getairportpower "$WIFI_DEVICE")"
else
    echo "Skipping Wi-Fi: no wireless interface was found." >&2
fi

blueutil --power off
echo "Bluetooth power: $(blueutil --power)"

# Suspend the logged-out audio loop once now and after each boot.
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

rm -f "$PLIST_TMP"
trap - EXIT

echo "Installed: suspend audiomxd once now and after each boot."
echo "Startup wait is limited to two minutes; there is no periodic retry after that."

echo
echo "Server setup complete."

# macOS requires approval in System Settings to install local profiles.
SERVER_PROFILE="$ROLE_DIR/profile.mobileconfig"
PROFILE_IDENTIFIER="$(plutil -extract PayloadIdentifier raw "$SERVER_PROFILE")"
PROFILE_INSTALLED=false
if sudo profiles list -type configuration | awk -v identifier="$PROFILE_IDENTIFIER" '
    $3 == "profileIdentifier:" && $4 == identifier { found = 1 }
    END { exit !found }
'; then
    PROFILE_INSTALLED=true
elif [ -z "${SSH_CONNECTION:-}" ]; then
    open "$SERVER_PROFILE" || echo "Open $SERVER_PROFILE manually to review and install it." >&2
fi

echo
if [ "$PROFILE_INSTALLED" = false ]; then
    echo "Remaining in System Settings:"
    echo "  - General > Device Management: install the server profile."
    echo "    Open $SERVER_PROFILE on this Mac first if it is not listed."
else
    echo "Server profile is already installed."
fi
echo "Optional cleanup: $ROLE_DIR/README.md"
echo "Then log out of the desktop."
