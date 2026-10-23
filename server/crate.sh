# Sourced by the scripts that install Bitview's crates or follow its mode. A
# mode is prod (crates.io), next or another branch of the official repository,
# or local (~/Developer/mono, which fleet copies from the workstation). Builds
# take their native-CPU flags from shared/home/.cargo/config.toml, linked
# during setup.

# The mode this mini was given, which ship install records, followed by the
# versions fleet pinned for it, bitviewd's then bitview_mcp's: a crates.io
# release in prod, a commit on a branch.
MODE_FILE="$HOME/.config/dots/mode"

# The build each of Bitview's workloads runs, as installed() named it when its
# supervisor started it, one file per crate, and the tokens the tunnels run on,
# as tokens_digest() named them. ship apply restarts a workload whose build
# installed differs, or the tunnels on new tokens, and fleet reads them for
# what each server runs.
RUNNING_DIR="$HOME/.config/dots/running"

# Each workload's failing exits, one line each, and beside it the end of its
# output then, which its block loses when start replaces it. ship status shows
# the last week's.
CRASH_LOG="$HOME/Library/Logs/dots/crashes.log"

# The build of CRATE installed, as cargo lists it: its version and, from git,
# its commit. A local build lists no change, so its binary's digest instead.
installed() {
    local line
    line="$(cargo install --list | awk -v crate="$1" '$1 == crate { print; exit }')"
    case "$line" in
        *" (/"*) shasum "$HOME/.cargo/bin/$1" ;;
        *) echo "$line" ;;
    esac
}

# The tunnel tokens fleet gave this mini, by their digest. Empty without any.
tokens_digest() {
    shasum "$SERVER_DIR/.tokens" 2>/dev/null | cut -d ' ' -f 1
}

# The mode bitviewd was installed in, by its source. Empty when cargo did not
# install bitviewd.
bitview_mode() {
    cargo install --list | awk '
        $1 == "bitviewd" {
            if (NF == 2) print "prod"
            else if ($3 ~ /^\(\//) print "local"
            else if ($3 ~ /[?&]branch=/) {
                sub(/.*[?&]branch=/, "", $3)
                sub(/[#&)].*/, "", $3)
                print $3
            }
            exit
        }'
}

# install_crate CRATE MODE [PIN] installs the PIN version, or the newest.
install_crate() {
    local crate="$1" mode="$2" pin="${3:-}"
    case "$mode" in
        prod)
            cargo install --locked "$crate" ${pin:+--version "$pin"}
            ;;
        local)
            # Build apart from the checkout's own target directory, so an
            # install neither replaces the binaries there nor makes the next
            # build there start over with other flags.
            cargo install --locked --path "$HOME/Developer/mono/crates/$crate" \
                --target-dir "$HOME/Library/Caches/dots/mono-target"
            ;;
        *)
            if [ -n "$pin" ]; then
                cargo install --locked --git https://github.com/bitcoinresearchkit/mono --rev "$pin" "$crate"
            else
                cargo install --locked --git https://github.com/bitcoinresearchkit/mono --branch "$mode" "$crate"
            fi
            ;;
    esac
}
