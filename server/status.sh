#!/usr/bin/env bash
set -euo pipefail

# ship status: one line for this mini, its mode and version, workloads,
# tunnels, sync, and disk. With --check, print nothing and exit 0 only when it
# serves: every workload runs, every tunnel is connected, and Bitview is at
# Bitcoin Core's tip. fleet update waits for that, as long as Bitview takes,
# but not for a workload that crashed since this Mac started, with nothing to
# start it again: that exits 2.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

case "$#:${1:-}" in
    0:) check=0 ;;
    1:--check) check=1 ;;
    *)
        echo "Usage: $0 [--check]" >&2
        exit 1
        ;;
esac

source "$SERVER_DIR/crate.sh"

# The tunnels fleet gave this mini; without any, tunnels.sh does not stay up.
names="$(awk '!/^#/ && NF { printf "%s%s", sep, $1; sep = " " }' "$SERVER_DIR/.tokens" 2>/dev/null || true)"

workloads=0
expected=3
down=''
for name in bitcoind bitviewd bitview_mcp; do
    if pgrep -x "$name" >/dev/null; then workloads=$((workloads + 1)); else down="$down $name"; fi
done
if [ -n "$names" ]; then
    expected=4
    if pgrep -f server/tunnels.sh >/dev/null; then workloads=$((workloads + 1)); else down="$down tunnels"; fi
fi

tunnels=0
ready=0
for pid in $(pgrep -x cloudflared || true); do
    tunnels=$((tunnels + 1))
    port="$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*://p' | head -1)"
    if [ -n "$port" ] && curl -s -m 3 "http://127.0.0.1:$port/ready" | jq -e '.readyConnections > 0' >/dev/null 2>&1; then
        ready=$((ready + 1))
    fi
done

behind="$(curl -s -m 5 http://127.0.0.1:3110/api/server/sync | jq -r '.blocks_behind // empty' 2>/dev/null || true)"

# The last week's failing exits, and the last one.
crashes="$(awk -v since="$(date -v-7d +%Y-%m-%dT%H:%M:%S)" '$1 >= since' "$CRASH_LOG" 2>/dev/null || true)"

if [ "$check" -eq 1 ]; then
    if [ "$workloads" -eq "$expected" ] && [ "$ready" -eq "$(wc -w <<< "$names")" ] &&
        [ "$ready" -eq "$tunnels" ] && [ "${behind:-1}" = 0 ]; then
        exit 0
    fi
    # A crashed workload's supervisor ends, and it stays down until ship start.
    booted="$(date -r "$(sysctl -n kern.boottime | sed -E 's/^[{] sec = ([0-9]+),.*/\1/')" +%Y-%m-%dT%H:%M:%S)"
    for name in $down; do
        [ "$name" != bitview_mcp ] || name=mcp
        pgrep -f "server/workloads.sh supervise $name\$" >/dev/null && continue
        if awk -v since="$booted" -v name="$name" '$1 >= since && $2 == name { found = 1 } END { exit !found }' \
            "$CRASH_LOG" 2>/dev/null; then
            exit 2
        fi
    done
    exit 1
fi

mode="$(awk '{ print $1; exit }' "$MODE_FILE" 2>/dev/null || true)"
mode="${mode:-$(bitview_mode)}"
version="$(cargo install --list | awk '$1 == "bitviewd" { sub(/:$/, ""); v = $2; if ($3 ~ /#/) { c = $3; sub(/.*#/, "", c); sub(/\).*/, "", c); v = v "#" substr(c, 1, 8) } print v; exit }')"
crashed=''
if [ -n "$crashes" ]; then
    crashed="$(awk 'END { sub(/T/, " ", $1); print NR " this week, last " $2 " at " substr($1, 6, 11) ", status " $NF }' <<< "$crashes")"
fi
# A macOS update ship fetch downloaded, which fleet update installs.
macos="$(sw_vers -productVersion)"
waiting="$(cat "$HOME/.config/dots/macos-downloaded" 2>/dev/null || true)"
[ "$waiting" != "$macos" ] || waiting=''
printf '%s %s, workloads %s/%s%s%s, tunnels %s %s/%s ready, %s behind, %s free, macOS %s%s, Rex %s, dots %s\n' \
    "${mode:-no mode}" "${version:-}" "$workloads" "$expected" "${down:+ (down:$down)}" "${crashed:+, crashes $crashed}" \
    "${names:-none}" "$ready" "$tunnels" \
    "${behind:-?}" "$(df -h /Volumes/External 2>/dev/null | awk 'NR == 2 { print $4 }')" \
    "$macos" "${waiting:+ ($waiting downloaded)}" \
    "$(rex --autostart=false server status 2>/dev/null | awk '$1 == "version:" { print $2; exit }')" \
    "$(git -C "$SERVER_DIR/.." log -1 --format=%h)"
