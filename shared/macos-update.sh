#!/usr/bin/env bash
set -e

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script only supports macOS." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the logged-in administrator, not with sudo." >&2
    exit 1
fi

CURRENT="$(sw_vers -productVersion)"
echo "Checking for updates to macOS $CURRENT..."
# --product-types prints a debug line and does not filter, so filter here.
LIST="$(softwareupdate --list 2>&1)"
# One line per update: label|title|version|size.
UPDATES="$(printf '%s\n' "$LIST" | awk '
    /^\* Label: / { label = substr($0, index($0, ": ") + 2); next }
    label != "" && /Title: / {
        line = $0
        sub(/^[ \t]+/, "", line)
        n = split(line, fields, ", ")
        title = version = size = ""
        for (i = 1; i <= n; i++) {
            if (fields[i] ~ /^Title: /) title = substr(fields[i], 8)
            else if (fields[i] ~ /^Version: /) version = substr(fields[i], 10)
            else if (fields[i] ~ /^Size: /) size = substr(fields[i], 7)
        }
        if (size ~ /KiB$/) size = sprintf("%.1f GB", substr(size, 1, length(size) - 3) * 1024 / 1e9)
        print label "|" title "|" version "|" size
        label = ""
    }
')"

if [ -z "$UPDATES" ] && ! printf '%s\n' "$LIST" | grep -q "No new software available"; then
    printf '%s\n' "$LIST" >&2
    echo "Could not read the list of updates." >&2
    exit 1
fi

OS_LABELS=()
OS_TITLES=()
OTHERS=()
echo
while IFS='|' read -r label title version size; do
    [ -n "$label" ] || continue
    case "$title" in
        macOS*)
            OS_LABELS+=("$label")
            OS_TITLES+=("$title")
            note=""
            major="${version%%.*}"
            case "$major" in
                '' | *[!0-9]*) ;;
                *) if [ "$major" -gt "${CURRENT%%.*}" ]; then note="  upgrade to macOS $major"; fi ;;
            esac
            printf '  %d  %-24s %9s%s\n' "${#OS_LABELS[@]}" "$title" "$size" "$note"
            ;;
        *)
            case "$title" in
                *" $version") ;;
                *) title="$title $version" ;;
            esac
            OTHERS+=("  $title: sudo softwareupdate --install '$label'")
            ;;
    esac
done <<< "$UPDATES"

if [ "${#OS_LABELS[@]}" -eq 0 ]; then
    echo "macOS is up to date."
fi
if [ "${#OTHERS[@]}" -gt 0 ]; then
    echo
    echo "Other updates, not installed by this script:"
    printf '%s\n' "${OTHERS[@]}"
fi
if [ "${#OS_LABELS[@]}" -eq 0 ]; then
    exit 0
fi

echo
if [ "${#OS_LABELS[@]}" -eq 1 ]; then
    read -r -p "Install ${OS_TITLES[0]} and restart? [y/N] " reply
    case "$reply" in
        y | Y | yes | Yes | YES) choice=1 ;;
        *) choice="" ;;
    esac
else
    read -r -p "Install which update? The Mac restarts afterwards. [1-${#OS_LABELS[@]}, Enter to cancel] " choice
fi
case "$choice" in
    '' | *[!0-9]*) choice=0 ;;
esac
if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#OS_LABELS[@]}" ]; then
    echo "Cancelled."
    exit 0
fi

sudo -v
sudo softwareupdate \
    --install "${OS_LABELS[$((choice - 1))]}" \
    --restart \
    --agree-to-license
