#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script only supports macOS." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi
echo "macOS server audit: $(scutil --get ComputerName 2>/dev/null || hostname)"
sw_vers -productVersion 2>/dev/null || true
echo
echo "== Homebrew services (user) =="
if brew_bin="$(command -v brew 2>/dev/null)"; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 "$brew_bin" services list 2>&1 ||
        echo "  unable to query user services"
    echo "== Homebrew services (system) =="
    if system_services="$(sudo -n /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 \
        "$brew_bin" services list 2>&1)"; then
        printf '%s\n' "$system_services"
    else
        printf '%s\n' "$system_services"
        echo "  (system query unavailable; retry with cached sudo credentials)"
    fi
else
    echo "  Homebrew is not on PATH"
fi
echo
plist_inventory() {
    local dir="$1" found=false
    printf '== Launch plists: %s ==\n' "$dir"
    if [ ! -d "$dir" ]; then
        echo "  (missing)"
        return
    fi
    for plist in "$dir"/*.plist; do
        [ -e "$plist" ] || [ -L "$plist" ] || continue
        found=true
        printf '  %s\n' "${plist##*/}"
    done
    [ "$found" = true ] || echo "  (none)"
}

plist_inventory /Library/LaunchDaemons
plist_inventory /Library/LaunchAgents
plist_inventory "$HOME/Library/LaunchAgents"
echo
echo "== Essential server launchd services =="
for service in \
    system/com.openssh.sshd \
    system/com.local.tailscaled \
    system/com.apple.smbd \
    system/com.apple.screensharing; do
    if service_info="$(launchctl print "$service" 2>/dev/null)"; then
        state="$(awk -F'= ' '$1 ~ /^[[:space:]]*state / { print $2; exit }' <<< "$service_info")"
        pid="$(awk -F'= ' '$1 ~ /^[[:space:]]*pid / { print $2; exit }' <<< "$service_info")"
        printf '  %-38s state=%s pid=%s\n' "$service" "${state:-loaded}" "${pid:--}"
    else
        printf '  %-38s not loaded or inaccessible\n' "$service"
    fi
done
echo
echo "== Spotlight =="
spotlight="$(mdutil -sa 2>&1 || true)"
if [ -n "$spotlight" ]; then
    printf '%s\n' "$spotlight"
else
    echo "  no status returned (try sudo -n mdutil -sa)"
fi
echo
echo "== Processes (names only) =="
if process_list="$(ps -axo pid=,user=,%cpu=,rss=,comm= 2>/dev/null)" && [ -n "$process_list" ]; then
    printf 'Top CPU:\n%-7s %-16s %6s %8s %s\n' PID USER CPU RSS_KB NAME
    printf '%s\n' "$process_list" | sort -k3,3nr | sed -n '1,12p'
    printf 'Top RSS:\n%-7s %-16s %6s %8s %s\n' PID USER CPU RSS_KB NAME
    printf '%s\n' "$process_list" | sort -k4,4nr | sed -n '1,12p'
else
    echo "  ps unavailable"
fi
