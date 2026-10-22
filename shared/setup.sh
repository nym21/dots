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
# Homebrew asks before each install or upgrade by default.
export HOMEBREW_NO_ASK=1 HOMEBREW_NO_ENV_HINTS=1

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

# The ship command on every Mac, and fleet on the workstation, reading the
# role to offer this Mac's commands. ship update runs this too, so renamed or
# new commands reach every Mac.
link_commands() {
    mkdir -p ~/.config/dots ~/.local/bin
    echo "$ROLE" > ~/.config/dots/role
    link "$SHARED_DIR/ship" ~/.local/bin/ship
    if [ "$ROLE" = pc ]; then
        link "$ROLE_DIR/fleet" ~/.local/bin/fleet
    fi
    # The command's earlier name.
    rm -f ~/.local/bin/dots
}

# Codex and Claude Code write machine state into their settings (trusted
# projects, hooks, auto mode), replacing a symlink or dirtying the repository
# through it. So the shared settings are merged into each machine's own file
# instead, overwriting the keys they set and keeping the rest; ship update
# merges them again.
merge_agent_settings() {
    local file tmp
    mkdir -p ~/.codex ~/.claude
    for file in ~/.codex/config.toml ~/.claude/settings.json; do
        if [ -L "$file" ]; then
            tmp="$(mktemp)"
            cat "$file" > "$tmp" 2>/dev/null || true
            rm "$file"
            mv "$tmp" "$file"
        fi
    done
    uv run --quiet "$SHARED_DIR/merge-toml.py" \
        "$SHARED_DIR/home/.codex/config.toml" ~/.codex/config.toml
    file=~/.claude/settings.json
    [ -s "$file" ] || echo '{}' > "$file"
    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' "$file" "$SHARED_DIR/home/.claude/settings.json" > "$tmp"
    mv "$tmp" "$file"
}

shared_setup() {
    mkdir -p "$HOME/Developer"

    # --- Commands ---
    link_commands

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

    # --- Cargo packages ---
    echo "Installing cargo packages..."
    cat "$SHARED_DIR/cargo.txt" "$ROLE_DIR/cargo.txt" 2>/dev/null |
        while IFS= read -r pkg || [ -n "$pkg" ]; do
            [ -n "$pkg" ] || continue
            echo "Installing ${pkg}..."
            cargo install --locked "$pkg" </dev/null
        done

    # --- Fish shell ---
    setup_fish_shell

    # --- Dotfiles ---
    echo "Linking dotfiles..."
    mkdir -p ~/.config/{fish,helix}

    git config --global diff.external difft
    git config --global core.editor hx

    link "$SHARED_DIR/home/.config/fish/config.fish" ~/.config/fish/config.fish
    link "$SHARED_DIR/home/.config/starship.toml" ~/.config/starship.toml
    link "$SHARED_DIR/home/.config/helix/config.toml" ~/.config/helix/config.toml

    # The firewall on, and Spotlight's index off: Raycast finds apps without
    # it, and a server has no use for one.
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
    sudo mdutil -a -i off >/dev/null

    "$SHARED_DIR/sudoers.sh"
}
