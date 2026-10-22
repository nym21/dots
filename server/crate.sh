# Sourced by the install scripts. install_crate CRATE [branch | --local]
# installs CRATE from crates.io, from a branch of the official repository, or
# from the checkout in ~/Developer/mono.

install_crate() {
    local crate="$1"
    case "${2:-}" in
        '')
            cargo install --locked "$crate"
            ;;
        --local)
            cargo install --locked --path "$HOME/Developer/mono/crates/$crate"
            ;;
        *)
            cargo install --locked \
                --git https://github.com/bitcoinresearchkit/mono --branch "$2" "$crate"
            ;;
    esac
}
