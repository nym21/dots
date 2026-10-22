#!/usr/bin/env bash
set -euo pipefail

# Install Sparrow Wallet, or update it, only once its download is proven its
# author's, as Sparrow's download page asks (https://sparrowwallet.com/download/):
# the release manifest must be signed by Craig Raw's PGP key, pinned here by
# fingerprint, and list the installer's SHA-256; the app must be signed by his
# Developer ID and notarized. A keyring of its own keeps your gpg's untouched.
#
#   sparrow.sh          install the newest release, when missing or older
#   sparrow.sh --check  only check the installed app's signature

KEY=D4D0D3202FC06849A257B38DE94618334C674B40
TEAM=UPLVMSK9D7
APP=/Applications/Sparrow.app
REPO=https://github.com/sparrowwallet/sparrow

# Whether the app at $1 is signed by Craig Raw's Developer ID, intact, and
# notarized.
signed() {
    codesign --verify --deep --strict "$1" 2>/dev/null &&
        [ "$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = "$TEAM" ] &&
        spctl --assess --type execute "$1" 2>/dev/null
}

installed="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
if [ -n "$installed" ] && ! signed "$APP"; then
    echo "$APP is not signed by Sparrow's author; remove it and run this again." >&2
    exit 1
fi
if [ "${1:-}" = --check ]; then
    [ -n "$installed" ] || { echo "Sparrow is not installed." >&2; exit 1; }
    echo "Sparrow $installed: signed by its author, notarized."
    exit 0
fi

version="$(curl -fsS -m 20 https://api.github.com/repos/sparrowwallet/sparrow/releases/latest | jq -r .tag_name)"
if [ -n "$installed" ] && [ "$(printf '%s\n%s\n' "$version" "$installed" | sort -V | tail -1)" = "$installed" ]; then
    exit 0
fi
if pgrep -xq Sparrow; then
    echo "Sparrow $version is out; quit Sparrow and run this again to install it." >&2
    exit 0
fi
command -v gpg >/dev/null || { echo "Verifying Sparrow needs gpg, from GPG Suite." >&2; exit 1; }

work="$(mktemp -d)"
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT
dmg="Sparrow-$version-aarch64.dmg"
manifest="sparrow-$version-manifest.txt"
echo "Downloading Sparrow $version..."
for file in "$dmg" "$manifest" "$manifest.asc"; do
    curl -fsSL -m 600 -o "$work/$file" "$REPO/releases/download/$version/$file"
done

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
curl -fsS -m 30 https://keybase.io/craigraw/pgp_keys.asc | gpg -q --import 2>/dev/null
if ! gpg --status-fd 1 --verify "$work/$manifest.asc" "$work/$manifest" 2>/dev/null |
    grep -qE "^\[GNUPG:\] VALIDSIG .*$KEY\$"; then
    echo "Sparrow $version's manifest is not signed by $KEY; not installing it." >&2
    exit 1
fi
expected="$(awk -v file="$dmg" '{ name = $2; sub(/^\*/, "", name) } name == file { print $1 }' "$work/$manifest")"
if [ -z "$expected" ] || [ "$(shasum -a 256 "$work/$dmg" | cut -d ' ' -f 1)" != "$expected" ]; then
    echo "$dmg does not match its signed manifest; not installing it." >&2
    exit 1
fi

hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mnt" "$work/$dmg"
if ! signed "$work/mnt/Sparrow.app"; then
    echo "Sparrow $version's app is not signed by its author; not installing it." >&2
    exit 1
fi
echo "Verified: manifest signed by $KEY, installer matching it, app signed and notarized."
rm -rf "$APP"
ditto "$work/mnt/Sparrow.app" "$APP"
signed "$APP"
echo "Installed Sparrow $version."
