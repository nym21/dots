#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

NETWORK_SERVICE="${NETWORK_SERVICE:-Ethernet}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 1.0.0.1}"
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
        echo "net.inet.tcp.delayed_ack=0"
        echo "kern.ipc.somaxconn=2048"
        echo "net.inet.tcp.always_keepalive=1"
        echo "# dots server sysctl end"
    } > "$tmp"

    sudo install -o root -g wheel -m 644 "$tmp" "$SYSCTL_CONF"
    rm -f "$tmp"
}

# Persistent TCP tuning. /etc/sysctl.conf is read during multi-user boot.
install_sysctl_conf
sudo sysctl -w net.inet.tcp.delayed_ack=0
sudo sysctl -w kern.ipc.somaxconn=2048
sudo sysctl -w net.inet.tcp.always_keepalive=1

# Cloudflare DNS on the wired service.
if networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$NETWORK_SERVICE"; then
    sudo networksetup -setdnsservers "$NETWORK_SERVICE" $DNS_SERVERS
else
    echo "Skipping DNS: network service '$NETWORK_SERVICE' was not found." >&2
fi

# Disable Spotlight indexing.
sudo mdutil -a -i off

# Keep the server reachable while allowing the display to sleep.
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1 powernap 0

# Normal OpenSSH over Tailscale. Tailscale provides private network access;
# sshd still handles authentication.
sudo systemsetup -setremotelogin on
sudo systemsetup -setremoteappleevents off

# Screen Sharing over Tailscale.
sudo launchctl enable system/com.apple.screensharing
sudo launchctl kickstart -k system/com.apple.screensharing

# Firewall.
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
