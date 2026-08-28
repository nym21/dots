#!/usr/bin/env bash
set -e

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

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
echo "Updating Homebrew..."
brew update
brew cleanup
echo "Installing and updating brew packages..."
brew bundle install --file="$DOTS_DIR/Brewfile"

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

# --- Codex ---
echo "Linking Codex settings..."
mkdir -p ~/.codex
link "$HOME_DIR/.codex/config.toml" ~/.codex/config.toml

# --- Cargo packages ---
echo "Installing cargo packages..."
while IFS= read -r pkg || [ -n "$pkg" ]; do
    echo "Installing ${pkg}..."
    [ -n "$pkg" ] && cargo install --locked "$pkg" || true
done < "$DOTS_DIR/cargo.txt"

echo "Updating cargo packages..."
cargo install-update --all --locked

# --- Fish shell ---
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

setup_fish_shell

# --- Dotfiles ---
echo "Linking dotfiles..."
mkdir -p ~/.config/{fish,ghostty,zed,tmux,helix}

git config --global diff.external difft
git config --global core.editor "zed --wait"

link "$HOME_DIR/.config/fish/config.fish" ~/.config/fish/config.fish
link "$HOME_DIR/.config/starship.toml" ~/.config/starship.toml
link "$HOME_DIR/.config/ghostty/config" ~/.config/ghostty/config
link "$HOME_DIR/.config/zed/settings.json" ~/.config/zed/settings.json
link "$HOME_DIR/.config/tmux/tmux.conf" ~/.config/tmux/tmux.conf
link "$HOME_DIR/.config/helix/config.toml" ~/.config/helix/config.toml

# --- macOS system ---
NETWORK_SERVICES=("Ethernet" "USB 10/100/1G/2.5G LAN")
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"

install_sysctl_conf() {
    local tmp
    tmp="$(mktemp)"

    {
        if [ -f "$SYSCTL_CONF" ]; then
            awk '
                $0 == "# dots server sysctl begin" { skip = 1; next }
                $0 == "# dots server sysctl end" { skip = 0; next }
                !skip { print }
            ' "$SYSCTL_CONF"
        fi

        echo "# dots server sysctl begin"
        echo "kern.ipc.somaxconn=2048"
        echo "# dots server sysctl end"
    } > "$tmp"

    sudo install -o root -g wheel -m 644 "$tmp" "$SYSCTL_CONF"
    rm -f "$tmp"
}

# Persistent TCP tuning. /etc/sysctl.conf is read during multi-user boot.
install_sysctl_conf
sudo sysctl -w kern.ipc.somaxconn=2048

# Cloudflare DNS on the wired services.
for service in "${NETWORK_SERVICES[@]}"; do
    if networksetup -listallnetworkservices | tail -n +2 | grep -Fxq "$service"; then
        sudo networksetup -setdnsservers "$service" "${DNS_SERVERS[@]}"
    else
        echo "Skipping DNS: network service '$service' was not found." >&2
    fi
done

# Disable Spotlight indexing.
sudo mdutil -a -i off

# Keep the machine reachable while allowing the display to sleep.
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1 powernap 0

# Normal OpenSSH over Tailscale. Tailscale provides private network access;
# sshd still handles authentication.
sudo systemsetup -setremotelogin on

# Screen Sharing over Tailscale.
sudo launchctl enable system/com.apple.screensharing
sudo launchctl kickstart -k system/com.apple.screensharing

# Firewall.
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

echo "Done! Restart your terminal."
