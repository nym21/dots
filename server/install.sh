#!/usr/bin/env bash

set -euo pipefail

# Set this mini's mode: install Bitview and the MCP server from crates.io
# (prod), a branch of the official repository (next), or the checkout in
# ~/Developer/mono (local). Then restart the daemons whose binary changed.

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [branch | --local]" >&2
    exit 1
fi

source "$(dirname "$0")/crate.sh"

checksum() {
    shasum "$HOME/.cargo/bin/$1" 2>/dev/null || true
}

bitviewd_before="$(checksum bitviewd)"
mcp_before="$(checksum bitview_mcp)"

rustup update
install_crate bitviewd "$@"
install_crate bitview_mcp "$@"

if [ ! -f /Library/LaunchDaemons/com.local.bitviewd.plist ]; then
    echo "Installed. Start the daemons with ./server/services.sh."
    exit 0
fi

# Restart only what changed, so a run with nothing new leaves a prod mini
# alone. The tunnels follow Bitview, whose install sets the mode, and restart
# last so they wait for both servers.
services=()
bitviewd_changed=0
if [ "$(checksum bitviewd)" != "$bitviewd_before" ]; then
    bitviewd_changed=1
    services+=(bitviewd)
fi
if [ "$(checksum bitview_mcp)" != "$mcp_before" ]; then
    services+=(bitview-mcp)
fi
if [ "$bitviewd_changed" -eq 1 ]; then
    services+=(tunnels)
fi

if [ "${#services[@]}" -eq 0 ]; then
    echo "Nothing changed; no daemon restarted."
    exit 0
fi
for service in "${services[@]}"; do
    [ -f "/Library/LaunchDaemons/com.local.$service.plist" ] || continue
    sudo launchctl kickstart -k "system/com.local.$service"
    echo "Restarted com.local.$service."
done
