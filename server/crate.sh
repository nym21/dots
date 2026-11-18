# Sourced by the scripts that install Bitview's crates or follow its mode. A
# mode is release (crates.io), prod, next or another branch of the official repository,
# or local (~/Developer/mono, which fleet copies from the workstation). Builds
# take their native-CPU flags from shared/home/.cargo/config.toml, linked
# during setup.

# The mode the builds installed were built in, followed by the versions fleet
# pinned for it, bitviewd's then bitview_mcp's: a crates.io release in
# release, a commit on a branch. ship install writes it once both built, so a
# build that fails leaves it naming what is installed.
MODE_FILE="$HOME/.config/dots/mode"

# The mode and build each of Bitview's workloads runs, as installed() named
# them when its supervisor started it, one file per crate. ship apply restarts
# a workload whose installed differs, and fleet reads them for what each
# server runs and in which mode. The tunnels keep their state there too
# (tunnels.sh).
RUNNING_DIR="$HOME/.config/dots/running"

# Each workload's failing exits, one line each, and beside it the end of its
# output then, which its block loses when start replaces it. ship status shows
# the last week's.
CRASH_LOG="$HOME/Library/Logs/dots/crashes.log"

# The mode of the builds installed, on a line of its own, then the build of
# CRATE, as cargo lists it: its version and, from git, its commit. A local
# build lists no change, so its binary's digest instead.
installed() {
    local line
    echo "mode $(awk '{ print $1; exit }' "$MODE_FILE" 2>/dev/null)"
    line="$(cargo install --list | awk -v crate="$1" '$1 == crate { print; exit }')"
    case "$line" in
        *" (/"*) shasum "$HOME/.cargo/bin/$1" ;;
        *) echo "$line" ;;
    esac
}

# The mode bitviewd was installed in, by its source. Empty when cargo did not
# install bitviewd.
bitview_mode() {
    cargo install --list | awk '
        $1 == "bitviewd" {
            if (NF == 2) print "release"
            else if ($3 ~ /^\(\//) print "local"
            else if ($3 ~ /[?&]branch=/) {
                sub(/.*[?&]branch=/, "", $3)
                sub(/[#&)].*/, "", $3)
                print $3
            }
            exit
        }'
}

# install_crate CRATE MODE [PIN] installs the PIN version, or the newest, and
# leaves one already installed. Only the binary named after CRATE: cargo takes
# an install as current only when it has every binary the package declares,
# so one behind a feature, as bitviewd 0.12.2's bitview-bindgen, would have
# it build the package again on every install.
install_crate() {
    local crate="$1" mode="$2" pin="${3:-}"
    case "$mode" in
        release)
            cargo install --locked "$crate" --bin "$crate" ${pin:+--version "$pin"}
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
                cargo install --locked --git https://github.com/bitcoinresearchkit/mono --rev "$pin" "$crate" --bin "$crate"
            else
                cargo install --locked --git https://github.com/bitcoinresearchkit/mono --branch "$mode" "$crate" --bin "$crate"
            fi
            ;;
    esac
}
