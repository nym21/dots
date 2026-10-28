#!/usr/bin/env bash
# pc/tunnel.sh: this Mac's tunnel, as a LaunchAgent, through an upgrade of
# cloudflared, with fakes for launchd, the running process, Homebrew's Cellar,
# and Mullvad's exclusion, run from a copy of pc/ with its own token file and
# fleet.conf. What the fakes record of their calls in $calls says what it did.
# shellcheck disable=SC2016,SC2329 # the stand-ins' own expansions, left for them; helpers check calls
source "$(dirname "$0")/lib.sh"
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/pc"
# Resolved, as the script resolves the binary's path: macOS's /var is a link.
cellar="$(cd "$TMP" && pwd -P)/Cellar/cloudflared"
calls="$TMP/calls"
for version in 2026.10.4 2026.10.5; do
    mkdir -p "$cellar/$version/bin"
    printf '#!/bin/bash\necho "cloudflared $* token=$TUNNEL_TOKEN" >> "%s"\n' "$calls" > "$cellar/$version/bin/cloudflared"
    chmod +x "$cellar/$version/bin/cloudflared"
done
old="$cellar/2026.10.4/bin/cloudflared"
new="$cellar/2026.10.5/bin/cloudflared"
ln -s "$old" "$TMP/bin/cloudflared"
# launchd, with the agent loaded while $TMP/loaded holds its process.
cat > "$TMP/bin/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$calls"
case "\$1" in
    print) [ -e "$TMP/loaded" ] || exit 113; printf '\tpid = %s\n' "\$(cat "$TMP/loaded")" ;;
    bootstrap) echo 101 > "$TMP/loaded" ;;
    bootout) rm -f "$TMP/loaded" ;;
esac
EOF
# The binary each running process started from, as PID BINARY lines.
cat > "$TMP/bin/lsof" <<EOF
#!/bin/bash
awk -v pid="\$2" '\$1 == pid { print "cloudflare " pid " k txt REG 1,4 1 1 " \$2 }' "$TMP/running"
EOF
chmod +x "$TMP/bin/launchctl" "$TMP/bin/lsof"
export PATH="$TMP/bin:$PATH"
cp "$REPO/pc/tunnel.sh" "$TMP/pc/"
printf '#!/bin/bash\necho split-tunnel >> "%s"\n' "$calls" > "$TMP/pc/split-tunnel.sh"
chmod +x "$TMP/pc/split-tunnel.sh"
printf 'prod p\nlocal tok\n' > "$TMP/pc/.tunnels"
printf '# server mode tunnels...\nm4-1 prod prod mcp\n' > "$TMP/pc/fleet.conf"
script="$TMP/pc/tunnel.sh"
plist="$HOME/Library/LaunchAgents/com.local.tunnel.plist"

tunnel() {
    : > "$calls"
    "$script" "$@"
}
called() {
    grep -Eq -- "$1" "$calls"
}
# Whether the first call matching A came before the first matching B.
before() {
    local a b
    a="$(grep -En -- "$1" "$calls" | head -1 | cut -d: -f1)"
    b="$(grep -En -- "$2" "$calls" | head -1 | cut -d: -f1)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

tunnel
check "the LaunchAgent is installed" called "launchctl bootstrap"
check "once the exclusion has moved" before split-tunnel "launchctl bootstrap"
check "and runs the tunnel" grep -q "<string>$script</string>" "$plist"

echo "101 $old" > "$TMP/running"
tunnel
check "while it runs the cloudflared installed, nothing changes" fails called "launchctl (bootstrap|bootout|kickstart)"

ln -sf "$new" "$TMP/bin/cloudflared"
tunnel
check "after an upgrade, it restarts onto the new cloudflared" called "launchctl kickstart -k"
check "once the exclusion has moved" before split-tunnel "launchctl kickstart"

echo "101 /bin/bash" > "$TMP/running"
tunnel
check "while it starts, before cloudflared, it is left alone" fails called kickstart

tunnel run
check "its run moves the exclusion before cloudflared starts" before split-tunnel "cloudflared tunnel"
check "and gives cloudflared the local tunnel's token" called "cloudflared tunnel --no-autoupdate run token=tok$"

echo "m4-1 local local" >> "$TMP/pc/fleet.conf"
tunnel
check "when fleet.conf gives the tunnel to a server, it stops" [ ! -e "$plist" ]
check "and the exclusion still moves" called split-tunnel
sed -i '' '$d' "$TMP/pc/fleet.conf"

tunnel
printf 'prod p\n' > "$TMP/pc/.tunnels"
tunnel
check "without its token, it stops" [ ! -e "$plist" ]
check "and its run fails" fails "$script" run
finish
