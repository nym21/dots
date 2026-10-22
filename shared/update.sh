#!/usr/bin/env bash
set -e

cloudflared_before="$(readlink -f "$(command -v cloudflared)" 2>/dev/null || true)"

brew upgrade
brew cleanup
cargo install-update --all --locked

# Mullvad's split tunneling excludes cloudflared by its versioned Cellar path,
# which an upgrade replaces. Move an existing exclusion to the current binary.
if command -v mullvad >/dev/null 2>&1 && command -v cloudflared >/dev/null 2>&1; then
    cloudflared_bin="$(readlink -f "$(command -v cloudflared)")"
    excluded="$(mullvad split-tunnel get | grep '/Cellar/cloudflared/.*/bin/cloudflared$' || true)"
    if [ -n "$excluded" ]; then
        while IFS= read -r path; do
            [ "$path" = "$cloudflared_bin" ] || mullvad split-tunnel app remove "$path"
        done <<< "$excluded"
        if ! grep -Fxq "$cloudflared_bin" <<< "$excluded"; then
            mullvad split-tunnel app add "$cloudflared_bin"
        fi
    fi
fi

# A running cloudflared keeps its old binary, so restart a server's tunnels when
# the upgrade replaced it, if they run in its Rex session. They come back once
# the node is ready; on prod, update one server at a time.
workloads="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/server/workloads.sh"
if pgrep -f server/tunnels.sh >/dev/null &&
    [ "$(readlink -f "$(command -v cloudflared)")" != "$cloudflared_before" ] &&
    rex --autostart=false ls --json 2>/dev/null |
        jq -e '.sessions[] | select(.label == "server")' >/dev/null; then
    "$workloads" stop tunnels
    "$workloads" start
fi

# Restart last: a server update may be running over this Tailscale connection.
if launchctl print system/com.local.tailscaled >/dev/null 2>&1; then
    sudo launchctl kickstart -k system/com.local.tailscaled
fi
