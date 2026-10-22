#!/usr/bin/env bash
set -euo pipefail

# Let ship update run as root, without a password, what it runs often: Apple's
# updates, and on a server the restarts of the daemons it updates. Anything
# else that needs root, such as installing a daemon, asks. It changes nothing
# when every rule is there, so ship update runs it just before a step that
# needs root: a missing rule asks for the password there, where the step
# would have, and that step and the next runs need none.

role="$(cat "$HOME/.config/dots/role")"
rules=(/usr/sbin/softwareupdate)
if [ "$role" = server ]; then
    rules+=("/bin/launchctl kickstart -k system/com.local.rex"
        "/bin/launchctl kickstart -k system/com.local.tailscaled")
fi
missing=0
for rule in "${rules[@]}"; do
    # shellcheck disable=SC2086
    sudo -n -l $rule >/dev/null 2>&1 || missing=1
done
[ "$missing" -eq 1 ] || exit 0

echo "Allowing ship update to restart its daemons and install Apple's updates without a password..."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
    echo "# Installed by dots: what ship update runs as root without a password."
    printf '%s ALL=(root) NOPASSWD: ' "$(id -un)"
    (IFS=','; printf '%s\n' "${rules[*]}" | sed 's/,/, /g')
} > "$tmp"
sudo visudo -cf "$tmp" >/dev/null
sudo install -o root -g wheel -m 440 "$tmp" /etc/sudoers.d/dots
