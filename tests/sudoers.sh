#!/usr/bin/env bash
# shared/sudoers.sh: the rules it keeps, read from sudo's listing as the minis
# print it, with a fake sudo that records what it would install.
source "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/repo/shared" "$TMP/bin" "$TMP/home/.config/dots"
cp "$REPO/shared/sudoers.sh" "$REPO/shared/lent.sh" "$TMP/repo/shared/"
echo server > "$TMP/home/.config/dots/role"
cat > "$TMP/bin/sudo" <<EOF
#!/bin/bash
if [ "\$*" = "-n -l" ]; then
    printf 'User mini may run the following commands on host:\n    (ALL) ALL\n    (root) NOPASSWD: %s\n' "\$LISTING"
    exit 0
fi
password=''
if [ "\$1" = -S ]; then IFS= read -r password; shift 3; fi
if [ "\$1" = install ]; then cp "\${@: -2:1}" "$TMP/written"; echo "\${password:+with password}" > "$TMP/how"; fi
EOF
chmod +x "$TMP/bin/sudo" "$TMP/repo/shared/sudoers.sh"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
script="$TMP/repo/shared/sudoers.sh"
old='/usr/sbin/softwareupdate, /bin/launchctl kickstart -k system/com.local.rex, /bin/launchctl kickstart -k system/com.local.tailscaled'
new='/usr/sbin/softwareupdate, /bin/launchctl kickstart -k system/com.local.rex'

LISTING="$old" "$script" < /dev/null > /dev/null
check "a retired rule waits for a password, without failing" [ ! -e "$TMP/written" ]

printf 'pw\n' | LISTING="$old" "$script" --stdinpass > /dev/null
check "with the password passed on, the rules are written" [ -e "$TMP/written" ]
check "without the retired one" lacks tailscaled "$TMP/written"
check "keeping the others" grep -q 'NOPASSWD: /usr/sbin/softwareupdate, /bin/launchctl kickstart -k system/com.local.rex$' "$TMP/written"
check "as root by the password given" grep -qx 'with password' "$TMP/how"
rm -f "$TMP/written"

LISTING="$new" "$script" < /dev/null > /dev/null
check "rules already right change nothing" [ ! -e "$TMP/written" ]

printf 'pw\n' | LISTING=/usr/sbin/softwareupdate "$script" --stdinpass > /dev/null
check "a missing rule is added" grep -q 'com.local.rex' "$TMP/written"
finish
