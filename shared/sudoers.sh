#!/usr/bin/env bash
set -euo pipefail

# Let ship update run as root, without a password, what it runs often: Apple's
# updates, and on a server the restart of the Rex server. Anything else that
# needs root, such as installing a daemon, asks. It changes nothing when the
# rules are as they should be, so ship update runs it just before a step that
# needs root: a missing rule asks for the password there, where the step
# would have, and that step and the next runs need none. One dots no longer
# makes, as the Tailscale daemon's restart, goes once a password is at hand.
# With --stdinpass, the password a script was lent comes on standard input.

source "$(dirname "$(readlink -f "$0")")/lent.sh" "$@"

role="$(cat "$HOME/.config/dots/role")"
rules=(/usr/sbin/softwareupdate)
if [ "$role" = server ]; then
    rules+=("/bin/launchctl kickstart -k system/com.local.rex")
fi

# The rules dots made that sudo has without a password, one per line, from
# its listing, which it gives without one once any exists. sudo -l of one
# command would not tell, as an administrator may run any, with a password.
current="$(sudo -n -l 2>/dev/null | sed -n 's/^ *(root) NOPASSWD: //p' |
    awk -F ', ' '{ for (i = 1; i <= NF; i++) print $i }' |
    grep -E '^(/usr/sbin/softwareupdate|/bin/launchctl kickstart -k system/com\.local\..*)$' || true)"
missing=0
for rule in "${rules[@]}"; do
    grep -Fxq "$rule" <<< "$current" || missing=1
done
extra=0
while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    printf '%s\n' "${rules[@]}" | grep -Fxq "$rule" || extra=1
done <<< "$current"
[ "$missing" -eq 1 ] || [ "$extra" -eq 1 ] || exit 0
# Removing one waits for a password, rather than fail what runs this without.
if [ "$missing" -eq 0 ] && [ -z "$lent_password" ] && [ ! -t 0 ]; then
    exit 0
fi

echo "Setting the rules ship update runs as root without a password..."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
    echo "# Installed by dots: what ship update runs as root without a password."
    printf '%s ALL=(root) NOPASSWD: ' "$(id -un)"
    (IFS=','; printf '%s\n' "${rules[*]}" | sed 's/,/, /g')
} > "$tmp"
as_root visudo -cf "$tmp" >/dev/null
as_root install -o root -g wheel -m 440 "$tmp" /etc/sudoers.d/dots
