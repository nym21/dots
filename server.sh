#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

NETWORK_SERVICE="${NETWORK_SERVICE:-Ethernet}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 1.0.0.1}"

# Reduce delayed ACK (helps cloudflared/brk + bitcoind p2p)
sudo sysctl -w net.inet.tcp.delayed_ack=0

# Increase listen backlog (bitcoind accepts inbound peers)
sudo sysctl -w kern.ipc.somaxconn=2048

# Detect dead connections (bitcoind peers, screen sharing)
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
