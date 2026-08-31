#!/usr/bin/env bash
set -e

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"
"$DOTS_DIR/import.sh" server

echo "Installing Bluetooth control..."
brew install blueutil

# Disable unused wireless radios. Refuse to turn off the server's active
# network path so a remote import cannot strand the machine.
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
    DEFAULT_INTERFACE="$(route -n get default 2>/dev/null | awk '$1 == "interface:" { print $2; exit }')"
    if [ "$DEFAULT_INTERFACE" = "$WIFI_DEVICE" ]; then
        echo "Refusing to disable Wi-Fi: '$WIFI_DEVICE' is the default network interface." >&2
        echo "Connect and verify Ethernet, then run the server import again." >&2
        exit 1
    fi

    sudo networksetup -setairportpower "$WIFI_DEVICE" off
    echo "Wi-Fi: $(networksetup -getairportpower "$WIFI_DEVICE")"
else
    echo "Skipping Wi-Fi: no wireless interface was found." >&2
fi

blueutil --power off
echo "Bluetooth power: $(blueutil --power)"
