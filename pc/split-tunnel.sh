#!/usr/bin/env bash
set -euo pipefail

# Mullvad's split tunneling excludes cloudflared by its versioned Cellar path,
# which an upgrade replaces. Through Mullvad, Cloudflare's tunnel servers are
# unreachable, so this moves an existing exclusion to the current binary:
# ship update runs it after upgrading, and fleet auto hourly, for an upgrade
# made otherwise.

command -v mullvad >/dev/null 2>&1 || exit 0
# Missing too while Homebrew relinks it, which the next run catches up on.
cloudflared_bin="$(readlink -f "$(command -v cloudflared)" 2>/dev/null)" || exit 0

excluded="$(mullvad split-tunnel get | grep '/Cellar/cloudflared/.*/bin/cloudflared$' || true)"
[ -n "$excluded" ] || exit 0
while IFS= read -r path; do
    [ "$path" = "$cloudflared_bin" ] || mullvad split-tunnel app remove "$path"
done <<< "$excluded"
if ! grep -Fxq "$cloudflared_bin" <<< "$excluded"; then
    mullvad split-tunnel app add "$cloudflared_bin"
fi
