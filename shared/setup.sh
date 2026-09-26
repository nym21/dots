#!/usr/bin/env bash
# Sourced by the role setup, which sets ROLE and runs shared_setup.

case "${ROLE:-}" in
    pc|server) ;;
    *)
        echo "Run ./pc/setup.sh or ./server/setup.sh." >&2
        exit 1
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This setup only supports macOS." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_DIR="$(dirname "$SHARED_DIR")/$ROLE"

link() {
    if [ -L "$2" ]; then
        [ "$(readlink "$2")" = "$1" ] && return 0
        rm "$2"
    elif [ -e "$2" ]; then
        if [ -e "$2.backup" ] || [ -L "$2.backup" ]; then
            echo "Refusing to overwrite existing backup: $2.backup" >&2
            return 1
        fi
        mv "$2" "$2.backup"
    fi
    ln -s "$1" "$2"
}

setup_fish_shell() {
    local fish_path
    fish_path="$(brew --prefix fish)/bin/fish"

    if [ ! -x "$fish_path" ]; then
        echo "Fish is not installed or not on PATH." >&2
        return 1
    fi

    if ! grep -qx "$fish_path" /etc/shells; then
        echo "Adding Fish to /etc/shells..."
        echo "$fish_path" | sudo tee -a /etc/shells >/dev/null
    fi

    if [ "$SHELL" != "$fish_path" ]; then
        chsh -s "$fish_path"
    fi

    if command -v launchctl >/dev/null 2>&1; then
        launchctl setenv SHELL "$fish_path" || true
    fi
}

shared_setup() {
    mkdir -p "$HOME/Developer"

    # --- Homebrew ---
    if ! command -v brew &> /dev/null; then
        if [ ! -x /opt/homebrew/bin/brew ]; then
            echo "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    echo "Updating Homebrew..."
    brew update
    brew cleanup
    echo "Installing and updating Homebrew formulae..."
    brew bundle install --file="$SHARED_DIR/Brewfile"
    echo "Installing and updating $ROLE packages..."
    brew bundle install --file="$ROLE_DIR/Brewfile"

    # --- Rust ---
    if ! command -v rustc &> /dev/null; then
        echo "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        rustup update
    fi

    # --- Cargo config ---
    echo "Linking cargo config..."
    mkdir -p ~/.cargo
    link "$SHARED_DIR/home/.cargo/config.toml" ~/.cargo/config.toml

    # --- Codex ---
    echo "Linking Codex settings..."
    mkdir -p ~/.codex
    link "$SHARED_DIR/home/.codex/config.toml" ~/.codex/config.toml

    # --- Cargo packages ---
    echo "Installing cargo packages..."
    while IFS= read -r pkg || [ -n "$pkg" ]; do
        [ -n "$pkg" ] || continue
        echo "Installing ${pkg}..."
        cargo install --locked "$pkg"
    done < "$SHARED_DIR/cargo.txt"

    # --- Fish shell ---
    setup_fish_shell

    # --- Dotfiles ---
    echo "Linking dotfiles..."
    mkdir -p ~/.config/{fish,tmux,helix}

    git config --global diff.external difft
    git config --global core.editor hx

    link "$SHARED_DIR/home/.config/fish/config.fish" ~/.config/fish/config.fish
    link "$SHARED_DIR/home/.config/starship.toml" ~/.config/starship.toml
    link "$SHARED_DIR/home/.config/tmux/tmux.conf" ~/.config/tmux/tmux.conf
    link "$SHARED_DIR/home/.config/tmux/save-layout.sh" ~/.config/tmux/save-layout.sh
    link "$SHARED_DIR/home/.config/tmux/restore-layout.sh" ~/.config/tmux/restore-layout.sh
    link "$SHARED_DIR/home/.config/helix/config.toml" ~/.config/helix/config.toml

    # Shared firewall setting.
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
}
