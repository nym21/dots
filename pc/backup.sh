#!/usr/bin/env bash
set -euo pipefail

# ship backup: back this Mac up with Time Machine, by hand, as its automatic
# backups stay off: they keep snapshots on the local disk while the backup
# disk is away. It leaves out what can be rebuilt or downloaded again, unlocks
# the backup disk, with its password from the keychain, backs up, and locks
# the disk again, which can then stay in or come out.

if [ "$#" -ne 0 ]; then
    echo "Usage: ship backup" >&2
    exit 1
fi

# shellcheck disable=SC2034 # read by shared/setup.sh
ROLE=pc
source "$(dirname "$(readlink -f "$0")")/../shared/setup.sh"

name="$(backup_name)"
if [ -z "$name" ]; then
    echo "Time Machine has no backup disk; choose one in System Settings > General > Time Machine." >&2
    exit 1
fi
volume="$(backup_volume "$name")"
if [ -z "$volume" ]; then
    echo "The backup disk $name is not in; put it in and run ship backup again." >&2
    exit 1
fi

# Rebuilt or downloaded again: Bitcoin Core's chain and Bitview's, from it;
# Rust's, Cargo's, and Bun's; caches; Xcode's simulators and builds; the
# Claude app's VM; and every project's build.
exclude=(
    "$HOME/Library/Application Support/Bitcoin"
    "$HOME/.bitview"
    "$HOME/Downloads"
    "$HOME/.rustup"
    "$HOME/.cargo"
    "$HOME/.bun"
    "$HOME/.cache"
    "$HOME/Library/Developer"
    "$HOME/Library/Application Support/Claude/vm_bundles"
)
echo "Leaving out what can be rebuilt or downloaded again..."
for path in "${exclude[@]}" "$HOME"/Developer/*/target; do
    [ -e "$path" ] || continue
    tmutil isexcluded "$path" | grep -q '^\[Excluded\]' || tmutil addexclusion "$path"
done

running() {
    tmutil status | grep -q 'Running = 1'
}

# Until the running backup ends, its phase and progress every half minute.
follow() {
    local line last=''
    while running; do
        line="$(tmutil status | awk -F ' = ' '
            /BackupPhase/ { gsub(/[";]/, "", $2); phase = $2 }
            /^ *Percent/ { gsub(/[";]/, "", $2); if ($2 >= 0) percent = sprintf(", %d%%", $2 * 100) }
            END { print phase percent }')"
        [ "$line" = "$last" ] || echo "  $line"
        last="$line"
        sleep 30
    done
}

# Its password, asked once, checked, and kept in the login keychain, so later
# backups unlock it without anyone there: macOS does not ask for a backup
# disk's. An unencrypted disk has none.
user="$(diskutil apfs listCryptoUsers "$volume" 2>/dev/null | awk '/^\+--/ { print $2; exit }')"
if [ -n "$user" ]; then
    item="dots backup disk $name"
    valid() {
        printf '%s' "$1" | diskutil apfs unlockVolume "$volume" -user "$user" -verify -stdinpassphrase >/dev/null 2>&1
    }
    # Exactly: security -w gives one that is not plain text, as with an
    # accent, as hex, which -g gives too, quoted text otherwise.
    kept() {
        local found
        found="$(security find-generic-password -s "$item" -g 2>&1 >/dev/null)" || return 0
        case "$found" in
            'password: 0x'*) found="${found#password: 0x}"; printf '%s' "${found%% *}" | xxd -r -p ;;
            'password: "'*) found="${found#password: \"}"; printf '%s' "${found%\"}" ;;
        esac
    }
    password="$(kept)"
    if [ -z "$password" ] || ! valid "$password"; then
        IFS= read -r -s -p "Password of the backup disk $name: " password </dev/tty
        echo
        if [ -z "$password" ]; then
            echo "No password reached ship backup; if you typed one, this terminal did not pass it on." >&2
            exit 1
        fi
        if ! valid "$password"; then
            echo "That is not $name's password." >&2
            exit 1
        fi
        # Given to security on its input, as hex, rather than in its
        # arguments, which any process can read.
        printf 'add-generic-password -U -s "%s" -a %s -X %s\n' "$item" "$USER" \
            "$(printf '%s' "$password" | xxd -p | tr -d '\n')" | security -i
        echo "Kept $name's password in the login keychain."
    fi
fi
if [ "$(diskutil info "$volume" | awk -F ': *' '/^ *Mounted:/ { print $2 }')" != Yes ]; then
    if [ -n "$user" ]; then
        printf '%s' "$password" | diskutil apfs unlockVolume "$volume" -stdinpassphrase >/dev/null
    else
        diskutil mount "$volume" >/dev/null
    fi
    echo "Unlocked $name."
fi
unset password

before="$(last_backup)"
if running; then
    echo "A backup to $name is already running; following it..."
else
    echo "Backing up to $name..."
    tmutil startbackup
    until running; do
        sleep 2
    done
fi
follow
after="$(last_backup)"
if [ -n "$after" ] && [ "$after" != "$before" ]; then
    echo "Backed up, at ${after% *}."
else
    echo "The backup did not complete; Time Machine's log says why." >&2
fi

# Unmounted and locked, not ejected: an ejected card is gone until put in
# again, while this one stays for the next backup, and can come out as safely.
# After a backup, macOS may keep the volume's key until the card comes out.
if [ -n "$user" ]; then
    diskutil apfs lockVolume "$volume" >/dev/null 2>&1 || diskutil unmount "$volume" >/dev/null
else
    diskutil unmount "$volume" >/dev/null
fi
if [ "$(diskutil info "$volume" | awk -F ': *' '/^ *Locked:/ { print $2 }')" = Yes ]; then
    echo "Unmounted and locked $name."
else
    echo "Unmounted $name; it can stay in, or come out, which locks it."
fi
