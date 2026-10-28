#!/usr/bin/env bash
set -euo pipefail

# Mullvad's split tunneling excludes cloudflared by its versioned Cellar path,
# which an upgrade replaces. Through Mullvad, Cloudflare's tunnel servers are
# unreachable, so this moves an existing exclusion to the current binary:
# ship update runs it after upgrading, and fleet auto hourly, for an upgrade
# made otherwise. A tunnel running still runs the binary it started from,
# whose path stays excluded until no cloudflared runs it, as removing it would
# cut that tunnel off until it restarts.

command -v mullvad >/dev/null 2>&1 || exit 0
# Missing too while Homebrew relinks it, which the next run catches up on.
cloudflared_bin="$(readlink -f "$(command -v cloudflared)" 2>/dev/null)" || exit 0

excluded="$(mullvad split-tunnel get | grep '/Cellar/cloudflared/.*/bin/cloudflared$' || true)"
[ -n "$excluded" ] || exit 0
# The binaries the running cloudflared processes started from.
running="$(for pid in $(pgrep -x cloudflared || true); do
    lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" { print $NF; exit }'
done | sort -u)"
keep="$(printf '%s\n%s\n' "$cloudflared_bin" "$running" | grep '/Cellar/cloudflared/.*/bin/cloudflared$' | sort -u)"
while IFS= read -r path; do
    grep -Fxq "$path" <<< "$keep" || mullvad split-tunnel app remove "$path"
done <<< "$excluded"
while IFS= read -r path; do
    grep -Fxq "$path" <<< "$excluded" || mullvad split-tunnel app add "$path"
done <<< "$keep"
