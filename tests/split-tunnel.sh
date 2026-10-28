#!/usr/bin/env bash
# pc/split-tunnel.sh: Mullvad's exclusion of cloudflared through an upgrade,
# with fakes for mullvad, the running cloudflared processes, and Homebrew's
# Cellar.
source "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/bin"
# Resolved, as the script resolves the binary's path: macOS's /var is a link.
cellar="$(cd "$TMP" && pwd -P)/Cellar/cloudflared"
for version in 2026.10.4 2026.10.5; do
    mkdir -p "$cellar/$version/bin"
    : > "$cellar/$version/bin/cloudflared"
    chmod +x "$cellar/$version/bin/cloudflared"
done
old="$cellar/2026.10.4/bin/cloudflared"
new="$cellar/2026.10.5/bin/cloudflared"
ln -s "$new" "$TMP/bin/cloudflared"
cat > "$TMP/bin/mullvad" <<EOF
#!/bin/bash
case "\$*" in
    "split-tunnel get") echo "Excluded applications:"; cat "$TMP/excluded" ;;
    "split-tunnel app add "*) echo "\$4" >> "$TMP/excluded" ;;
    "split-tunnel app remove "*) grep -Fxv "\$4" "$TMP/excluded" > "$TMP/excluded.new"; mv "$TMP/excluded.new" "$TMP/excluded" ;;
esac
EOF
cat > "$TMP/bin/pgrep" <<EOF
#!/bin/bash
[ "\$*" = "-x cloudflared" ] || exec /usr/bin/pgrep "\$@"
[ -s "$TMP/running" ] && sed 's/ .*//' "$TMP/running"
EOF
cat > "$TMP/bin/lsof" <<EOF
#!/bin/bash
awk -v pid="\$2" '\$1 == pid { print "cloudflare " pid " k txt REG 1,4 1 1 " \$2 }' "$TMP/running"
EOF
chmod +x "$TMP/bin/mullvad" "$TMP/bin/pgrep" "$TMP/bin/lsof"
export PATH="$TMP/bin:$PATH"
script="$REPO/pc/split-tunnel.sh"

# Run it with EXCLUDED, and cloudflared processes as PID BINARY lines.
run() {
    printf '%s\n' "$1" | sed '/^$/d' > "$TMP/excluded"
    printf '%s\n' "$2" | sed '/^$/d' > "$TMP/running"
    "$script"
}
excluded() {
    sort "$TMP/excluded" | tr '\n' ' '
}

run "$old" "101 $old"
check "after an upgrade, the new binary is excluded" grep -Fxq "$new" "$TMP/excluded"
check "and the old one too, while a tunnel still runs it" grep -Fxq "$old" "$TMP/excluded"

run "$(printf '%s\n%s' "$old" "$new")" "102 $new"
check "once that tunnel runs the new one, the old one goes" [ "$(excluded)" = "$new " ]

run "$old" ""
check "with no tunnel running, the exclusion moves to the new binary" [ "$(excluded)" = "$new " ]

run "" "101 $old"
check "with nothing excluded, nothing is added" [ ! -s "$TMP/excluded" ]
finish
