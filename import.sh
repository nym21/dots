#!/usr/bin/env bash
set -e

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$DOTS_DIR/home"

link() {
    [ -e "$2" ] && [ ! -L "$2" ] && mv "$2" "$2.backup"
    [ -L "$2" ] && rm "$2"
    ln -s "$1" "$2"
}

# --- Homebrew ---
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo "Installing brew packages..."
brew bundle install --no-upgrade --file="$DOTS_DIR/Brewfile"

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
link "$HOME_DIR/.cargo/config.toml" ~/.cargo/config.toml

# --- Cargo packages ---
echo "Installing cargo packages..."
while IFS= read -r pkg || [ -n "$pkg" ]; do
    echo "Installing ${pkg}..."
    [ -n "$pkg" ] && cargo install "$pkg" || true
done < "$DOTS_DIR/cargo.txt"

# --- Fish shell ---
setup_fish_shell() {
    local fish_path
    fish_path="$(brew --prefix fish)/bin/fish"

    if [ ! -x "$fish_path" ]; then
        echo "Fish is not installed or not on PATH." >&2
        return 1
    fi

    local old_fish_path
    old_fish_path="$HOME/.cargo/bin/fish"

    if grep -qx "$old_fish_path" /etc/shells; then
        echo "Removing old Cargo Fish from /etc/shells..."
        local shells_tmp
        shells_tmp="$(mktemp)"
        awk -v old="$old_fish_path" '$0 != old' /etc/shells > "$shells_tmp"
        sudo cp "$shells_tmp" /etc/shells
        rm -f "$shells_tmp"
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

setup_fish_shell

# --- Dotfiles ---
echo "Linking dotfiles..."
mkdir -p ~/.config/{fish,ghostty,zed,zellij,helix}

git config --global diff.external difft
git config --global core.editor "zed --wait"

link "$HOME_DIR/.config/fish/config.fish" ~/.config/fish/config.fish
link "$HOME_DIR/.config/starship.toml" ~/.config/starship.toml
link "$HOME_DIR/.config/ghostty/config" ~/.config/ghostty/config
link "$HOME_DIR/.config/zed/settings.json" ~/.config/zed/settings.json
link "$HOME_DIR/.config/zellij/config.kdl" ~/.config/zellij/config.kdl
link "$HOME_DIR/.config/helix/config.toml" ~/.config/helix/config.toml

echo "Done! Restart your terminal."
