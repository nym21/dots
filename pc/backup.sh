#!/usr/bin/env bash
set -euo pipefail

# ship backup: back this Mac up with Time Machine, by hand, as its automatic
# backups stay off: they keep snapshots on the local disk while the backup
# disk is away. It leaves out what can be rebuilt or downloaded again, unlocks
# the backup disk, asking for its password when it is locked, backs up, and
# ejects the disk once done.

if [ "$#" -ne 0 ]; then
    echo "Usage: ship backup" >&2
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

# The backup volume, by the name Time Machine last knew it under.
name="$(defaults read /Library/Preferences/com.apple.TimeMachine Destinations 2>/dev/null |
    sed -nE 's/^ *LastKnownVolumeName = "?([^";]+)"?;$/\1/p' | head -1)"
if [ -z "$name" ]; then
    echo "Time Machine has no backup disk; choose one in System Settings > General > Time Machine." >&2
    exit 1
fi
volume="$(diskutil apfs list -plist | plutil -convert json -o - - |
    jq -r --arg name "$name" '.Containers[].Volumes[] | select(.Name == $name) | .DeviceIdentifier' | head -1)"
if [ -z "$volume" ]; then
    echo "Connect the backup disk $name, then run ship backup again." >&2
    exit 1
fi
# Its password, asked once and kept in the login keychain, so later backups
# unlock it without anyone there: macOS does not ask for a backup disk's.
if [ "$(diskutil info "$volume" | awk -F ': *' '/^ *Mounted:/ { print $2 }')" != Yes ]; then
    item="dots backup disk $name"
    password="$(security find-generic-password -s "$item" -w 2>/dev/null || true)"
    if [ -z "$password" ] || ! printf '%s' "$password" | diskutil apfs unlockVolume "$volume" -stdinpassphrase >/dev/null; then
        read -r -s -p "Password of the backup disk $name: " password </dev/tty
        echo
        printf '%s' "$password" | diskutil apfs unlockVolume "$volume" -stdinpassphrase >/dev/null
        security add-generic-password -U -s "$item" -a "$USER" -w "$password"
        echo "Unlocked $name, its password kept in the login keychain for next time."
    else
        echo "Unlocked $name."
    fi
    unset password
fi

before="$(tmutil latestbackup 2>/dev/null || true)"
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
after="$(tmutil latestbackup 2>/dev/null || true)"
if [ -n "$after" ] && [ "$after" != "$before" ]; then
    echo "Backed up: ${after##*/}"
else
    echo "The backup did not complete; Time Machine's log says why." >&2
fi

# The disk under the volume's APFS container, ejected whole.
store="$(diskutil info "$volume" | awk -F ': *' '/APFS Physical Store/ { print $2 }')"
disk="$(diskutil info "${store:-$volume}" | awk -F ': *' '/Part of Whole/ { print $2 }')"
diskutil eject "$disk" >/dev/null && echo "Ejected $name."
