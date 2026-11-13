#!/usr/bin/env bash
set -euo pipefail

# A new login password for this Mac's user: five random words from the EFF's
# large list (about 64 bits), shown once to you in the terminal and typed back
# to confirm, then set everywhere that holds it, so nothing breaks:
#
#   the account                 dscl, with the current password
#   the login keychain          re-keyed, so every saved login still opens
#   "agent mac password"        the keychain item sudo and the agents read
#   automatic login             /etc/kcpassword, when this user logs in by itself
#
# The current password is read from the "agent mac password" item, so run it
# as the user it belongs to, in a terminal.
#
#   password.sh

ITEM="agent mac password"
LIST_URL=https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
LIST_SHA256=addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORDS=5

fail() { echo "error: $*" >&2; exit 1; }

[ "$#" -eq 0 ] || { echo "Usage: $0" >&2; exit 1; }
[ -t 0 ] && [ -t 1 ] || fail "run it in a terminal: it shows the new password to you"

user="$(id -un)"
old="$(security find-generic-password -s "$ITEM" -a "$user" -w 2>/dev/null)" ||
    old="$(security find-generic-password -s "$ITEM" -w 2>/dev/null)" ||
    fail "no \"$ITEM\" item in the keychain"
dscl . -authonly "$user" "$old" 2>/dev/null ||
    fail "\"$ITEM\" no longer opens $user's account; fix that first"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$LIST_URL" -o "$tmp/words"
[ "$(shasum -a 256 "$tmp/words" | cut -d' ' -f1)" = "$LIST_SHA256" ] ||
    fail "the word list doesn't match its known checksum"
new="$(python3 -c '
import secrets, sys
words = [line.split()[1] for line in open(sys.argv[1]) if line.strip()]
assert len(words) == 7776
print("-".join(secrets.choice(words) for _ in range(int(sys.argv[2]))))
' "$tmp/words" "$WORDS")"

echo
echo "  New password for $user:"
echo
echo "      $new"
echo
echo "  Keep it somewhere other than this Mac. Keychain Access asks for it"
echo "  before showing any saved password, this one included."
echo
read -r -s -p "  Type it back to set it (or Ctrl-C to keep the current one): " again
echo
[ "$again" = "$new" ] || fail "that doesn't match; nothing changed"
clear

printf '%s\n' "$old" | sudo -S -p '' -v
# The account first: the rest follows it, and stops on the first failure, saying where.
dscl . -passwd "/Users/$user" "$old" "$new" || fail "the account's password didn't change; nothing changed"
security set-keychain-password -o "$old" -p "$new" "$KEYCHAIN" 2>/dev/null ||
    security unlock-keychain -p "$new" "$KEYCHAIN" 2>/dev/null ||
    fail "the account changed but the login keychain didn't: run security set-keychain-password by hand"
security add-generic-password -U -s "$ITEM" -a "$user" -w "$new" "$KEYCHAIN"
if [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$user" ]; then
    # Automatic login's file: the password and a terminator, padded to 12
    # bytes, XORed with Apple's fixed key; read only by loginwindow.
    printf '%s' "$new" | sudo python3 -c '
import os, sys
KEY = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
data = sys.stdin.buffer.read() + b"\0"
data += b"\0" * (-len(data) % 12)
fd = os.open("/etc/kcpassword", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, bytes(b ^ KEY[i % len(KEY)] for i, b in enumerate(data)))
os.close(fd)
'
fi
sudo -k

# Each part checked with the new password alone.
dscl . -authonly "$user" "$new" || fail "the account doesn't take the new password"
security unlock-keychain -p "$new" "$KEYCHAIN" || fail "the login keychain doesn't take the new password"
[ "$(security find-generic-password -s "$ITEM" -a "$user" -w)" = "$new" ] || fail "\"$ITEM\" wasn't updated"
printf '%s\n' "$new" | sudo -S -p '' -v || fail "sudo doesn't take the new password"
sudo -k
echo "Done: $user's password changed, its keychain, \"$ITEM\" and automatic login follow it."
