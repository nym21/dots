# Sourced by install.sh and bench.sh. install_crate CRATE [branch | --local]
# installs CRATE from crates.io, from a branch of the official repository, or
# from the checkout in ~/Developer/mono. Builds take their native-CPU flags
# from shared/home/.cargo/config.toml, linked during setup.

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
