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
for path in "${exclude[@]}" "$HOME"/Developer/*/target; do
    [ -e "$path" ] || continue
    tmutil isexcluded "$path" | grep -q '^\[Excluded\]' || tmutil addexclusion "$path"
done

if tmutil status | grep -q 'Running = 1'; then
    echo "A backup is already running." >&2
    exit 1
fi

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
if [ "$(diskutil info "$volume" | awk -F ': *' '/^ *Mounted:/ { print $2 }')" != Yes ]; then
    echo "Unlocking $name..."
    diskutil apfs unlockVolume "$volume"
fi

echo "Backing up to $name; the first backup takes a while..."
tmutil startbackup --block
echo "Backed up: $(tmutil latestbackup 2>/dev/null | sed 's#.*/##')"

# The disk under the volume's APFS container, ejected whole.
store="$(diskutil info "$volume" | awk -F ': *' '/APFS Physical Store/ { print $2 }')"
disk="$(diskutil info "${store:-$volume}" | awk -F ': *' '/Part of Whole/ { print $2 }')"
diskutil eject "$disk" >/dev/null && echo "Ejected $name."
