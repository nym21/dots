#!/usr/bin/env bash
set -e

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(dirname "$PC_DIR")/shared"

# Imported dotfiles are symlinks; edit the files in shared/home/ directly.
echo "Exporting Cargo packages..."
packages="$(cargo install --list)"
# The tools both roles use stay in shared/cargo.txt; the rest is this Mac's.
# Server workloads install their own crates; keep them out of both lists.
printf '%s\n' "$packages" | awk '
    /^[[:alnum:]_-]+ v[^ ]+:$/ && $1 !~ /^(bitviewd|bitviewd_bench|bitview_mcp)$/ { print $1 }
' | grep -vxF -f "$SHARED_DIR/cargo.txt" > "$PC_DIR/cargo.txt" || true

# Rex keeps its settings in its preferences, which it rewrites, so save them
# for pc/setup.sh to write back. Only plain values are kept; the data and
# dictionaries hold its state, such as the last focused session.
if defaults read com.superlogical.rex >/dev/null 2>&1; then
    echo "Exporting Rex settings..."
    {
        echo "# Rex app settings, KEY TYPE VALUE: saved by pc/save.sh, written by pc/setup.sh."
        defaults export com.superlogical.rex - | plutil -convert xml1 -o - - |
            grep -oE '<key>Workspace\.[A-Za-z0-9.]+</key>' | sed -E 's#</?key>##g' | sort -u |
            while read -r key; do
                value="$(defaults read com.superlogical.rex "$key")"
                case "$(defaults read-type com.superlogical.rex "$key")" in
                    *boolean) type=bool; [ "$value" = 1 ] && value=true || value=false ;;
                    *integer) type=int ;;
                    *float) type=float ;;
                    *string) type=string ;;
                    *) continue ;;
                esac
                echo "$key $type $value"
            done
    } > "$PC_DIR/rex-settings"
fi

echo "Done!"
