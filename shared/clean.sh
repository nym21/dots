#!/usr/bin/env bash
set -euo pipefail

# ship clean: free the space that caches and old builds take, keeping what is
# in use; all of it comes back on its own when needed. ship update runs it
# before macOS's update, so the servers clean up with every fleet update.
#
#   - Homebrew's downloads and the dependencies nothing needs any more
#   - Rust toolchains but the default and those a project in ~/Developer pins
#   - Cargo's extracted sources and git checkouts, which it recreates, and
#     crates downloaded over 90 days ago, unless a build is running
#   - a project's target directory in ~/Developer unbuilt for 30 days
#   - on the workstation, every simulator runtime but the newest stable iOS,
#     so no older iOS, tvOS, or watchOS; Bun's download cache; and the
#     releases of Codex's packages but the one it runs
#   - on a server, the local-mode build directory once it runs another mode
#   - crash logs over 90 days old

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROLE="$(cat "$HOME/.config/dots/role")"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export HOMEBREW_NO_ASK=1 HOMEBREW_NO_ENV_HINTS=1

free() {
    df -k "$HOME" | awk 'NR == 2 { print $4 }'
}
before="$(free)"

echo "Cleaning Homebrew..."
brew autoremove -q >/dev/null
brew cleanup -q --prune=all >/dev/null

echo "Cleaning Rust..."
default="$(rustup default | cut -d ' ' -f 1)"
pinned="$(for file in "$HOME"/Developer/*/rust-toolchain.toml "$HOME"/Developer/*/rust-toolchain; do
    [ -f "$file" ] || continue
    if [ "${file##*.}" = toml ]; then
        sed -nE 's/^channel *= *"([^"]+)".*/\1/p' "$file"
    else
        head -1 "$file"
    fi
done)"
for toolchain in $(rustup toolchain list | awk '{ print $1 }'); do
    [ "$toolchain" != "$default" ] || continue
    grep -qxF "${toolchain%-aarch64-apple-darwin}" <<< "$pinned" && continue
    rustup toolchain uninstall "$toolchain"
done
if pgrep -xq cargo || pgrep -xq rustc; then
    echo "  A build is running; Cargo's caches are left for next time."
else
    rm -rf "$HOME/.cargo/registry/src" "$HOME/.cargo/git/checkouts"
    find "$HOME/.cargo/registry/cache" -name '*.crate' -mtime +90 -delete 2>/dev/null || true
fi
for target in "$HOME"/Developer/*/target; do
    [ -f "$(dirname "$target")/Cargo.toml" ] || continue
    if [ -z "$(find "$target" -maxdepth 2 -mtime -30 2>/dev/null | head -1)" ]; then
        echo "  ${target#"$HOME"/}, unbuilt for 30 days"
        rm -rf "$target"
    fi
done

case "$ROLE" in
    pc)
        rm -rf "$HOME/.bun/install/cache"
        for package in "$HOME"/.codex/packages/*/; do
            current="$(readlink "${package}current" 2>/dev/null || true)"
            [ -n "$current" ] && [ -d "$current" ] || continue
            for release in "${package}releases"/*; do
                [ "$release" = "$current" ] || rm -rf "$release"
            done
        done
        if xcrun --find simctl >/dev/null 2>&1; then
            echo "Cleaning Xcode's simulators..."
            # A beta's build ends in a lowercase letter.
            runtimes="$(xcrun simctl runtime list --json |
                jq -r 'to_entries[].value | [.identifier, .platformIdentifier, .version, .build] | @tsv')"
            keep="$(awk -F '\t' '$2 == "com.apple.platform.iphonesimulator" && $4 !~ /[a-z]$/ { print $3 "\t" $1 }' \
                <<< "$runtimes" | sort -V | tail -1 | cut -f 2)"
            if [ -n "$keep" ]; then
                for runtime in $(awk -F '\t' -v keep="$keep" '$1 != keep { print $1 }' <<< "$runtimes"); do
                    xcrun simctl runtime delete "$runtime"
                done
            fi
            xcrun simctl delete unavailable
        fi
        ;;
    server)
        source "$DOTS_DIR/server/crate.sh"
        if [ "$(awk '{ print $1; exit }' "$MODE_FILE" 2>/dev/null)" != local ]; then
            rm -rf "$HOME/Library/Caches/dots/mono-target"
        fi
        find "$(dirname "$CRASH_LOG")" -name '*-*.log' -mtime +90 -delete 2>/dev/null || true
        ;;
esac

awk -v before="$before" -v after="$(free)" 'BEGIN { printf "Freed %.1f GB.\n", (after - before) / 1048576 }'
