#!/usr/bin/env bash
set -euo pipefail

# Mullvad's split tunneling excludes some daemons by their versioned Cellar
# paths, which an upgrade replaces:
#
#   cloudflared   Cloudflare's tunnel servers are unreachable through Mullvad.
#   tailscaled    tssh's tailnet node: through Mullvad, its packets ride
#                 inside Mullvad's tunnel, which holds the direct paths to the
#                 phone and the servers to Mullvad's speed and MTU; outside
#                 it, Tailscale still encrypts them end to end.
#   bitcoind      the node's sync and peers, several times faster outside it;
#                 its peers see this Mac's address, as a node's do.
#
# This excludes each one's current binary: first when setup runs it, then
# after each upgrade, when pc/tunnel.sh runs it, as ship update and fleet auto
# do that, and before this Mac's tunnel starts. A daemon running still runs
# the binary it started from, whose path stays excluded until no process runs
# it, as removing it would cut that daemon off until it restarts.

command -v mullvad >/dev/null 2>&1 || exit 0

excluded_list="$(mullvad split-tunnel get)"

# exclude BINARY FORMULA
exclude() {
    local name="$1" pattern="/Cellar/$2/.*/bin/$1\$" current excluded running keep path
    # Missing too while Homebrew relinks it, which the next run catches up on.
    current="$(readlink -f "$(command -v "$name")" 2>/dev/null)" || return 0
    excluded="$(grep "$pattern" <<< "$excluded_list" || true)"
    # The binaries the running processes started from.
    running="$(for pid in $(pgrep -x "$name" || true); do
        # Read to the end: stopping early breaks the pipe from lsof, failing the run.
        lsof -p "$pid" 2>/dev/null | awk '$4 == "txt" && !done { print $NF; done = 1 }'
    done | sort -u)"
    keep="$(printf '%s\n%s\n' "$current" "$running" | grep "$pattern" | sort -u)"
    while IFS= read -r path; do
        [ -z "$path" ] || grep -Fxq "$path" <<< "$keep" || mullvad split-tunnel app remove "$path"
    done <<< "$excluded"
    while IFS= read -r path; do
        [ -z "$path" ] || grep -Fxq "$path" <<< "$excluded" || mullvad split-tunnel app add "$path"
    done <<< "$keep"
}

exclude cloudflared cloudflared
exclude tailscaled tailscale
exclude bitcoind bitcoin
