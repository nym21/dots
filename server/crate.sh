# Sourced by the scripts that install Bitview's crates or follow its mode.
# Builds take their native-CPU flags from shared/home/.cargo/config.toml,
# linked during setup.

# This mini's mode, from how bitviewd was installed: prod from crates.io, the
# branch name from a branch of the official repository, local from the
# checkout. Empty when cargo did not install bitviewd.
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

# install_crate CRATE [branch | --local] installs CRATE from crates.io, from a
# branch of the official repository, or from the checkout in ~/Developer/mono.
install_crate() {
    local crate="$1"
    case "${2:-}" in
        '')
            cargo install --locked "$crate"
            ;;
        --local)
            # Build apart from the checkout's own target directory, so an
            # install neither replaces the binaries there nor makes the next
            # build there start over with other flags.
            cargo install --locked --path "$HOME/Developer/mono/crates/$crate" \
                --target-dir "$HOME/Library/Caches/dots/mono-target"
            ;;
        *)
            cargo install --locked \
                --git https://github.com/bitcoinresearchkit/mono --branch "$2" "$crate"
            ;;
    esac
}
