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
brew bundle --file="$DOTS_DIR/Brewfile"

# --- Rust ---
if ! command -v rustc &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# --- Cargo packages ---
echo "Installing cargo packages..."
while IFS= read -r pkg || [ -n "$pkg" ]; do
    [ -n "$pkg" ] && cargo install "$pkg" 2>/dev/null || true
done < "$DOTS_DIR/cargo-packages.txt"

while IFS= read -r url || [ -n "$url" ]; do
    [ -n "$url" ] && cargo install --git "$url" 2>/dev/null || true
done < "$DOTS_DIR/cargo-git-packages.txt"

# --- Dotfiles ---
echo "Linking dotfiles..."
mkdir -p ~/.config/{fish,ghostty,zed}

git config --global diff.external difft
git config --global core.editor "zed --wait"

link "$HOME_DIR/.config/fish/config.fish" ~/.config/fish/config.fish
link "$HOME_DIR/.config/starship.toml" ~/.config/starship.toml
link "$HOME_DIR/.config/ghostty/config" ~/.config/ghostty/config
link "$HOME_DIR/.config/zed/settings.json" ~/.config/zed/settings.json

echo "Done! Restart your terminal."
