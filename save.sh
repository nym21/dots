#!/usr/bin/env bash
set -e

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Imported dotfiles are symlinks; edit the files in home/ directly.
echo "Exporting Cargo packages..."
packages="$(cargo install --list)"
printf '%s\n' "$packages" | awk '/^[[:alnum:]_-]+ v[^ ]+:$/ { print $1 }' > "$DOTS_DIR/cargo.txt"

echo "Done!"
