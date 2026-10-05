#!/usr/bin/env bash
set -e

SHARED_DIR="$(cd "$(dirname "$0")" && pwd)"

# Imported dotfiles are symlinks; edit the files in shared/home/ directly.
echo "Exporting Cargo packages..."
packages="$(cargo install --list)"
# Server workloads install their own crates; keep them out of the shared list.
printf '%s\n' "$packages" | awk '
    /^[[:alnum:]_-]+ v[^ ]+:$/ && $1 !~ /^(bitviewd|bitviewd_bench|bitview_mcp)$/ { print $1 }
' > "$SHARED_DIR/cargo.txt"

echo "Done!"
