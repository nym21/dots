#!/usr/bin/env bash
set -e

ROLE="${1:-}"

case "$ROLE" in
    pc|server) ;;
    *)
        echo "Use ./import-pc.sh or ./import-server.sh." >&2
        exit 1
        ;;
esac

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
echo "Installing and updating Homebrew formulae..."
brew bundle install --file="$DOTS_DIR/Brewfile"
if [ "$ROLE" = "pc" ]; then
    echo "Installing and updating Homebrew casks..."
    brew bundle install --file="$DOTS_DIR/Brewfile.pc"
fi

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
mkdir -p ~/.config/{fish,tmux,helix}

git config --global diff.external difft

link "$HOME_DIR/.config/fish/config.fish" ~/.config/fish/config.fish
link "$HOME_DIR/.config/starship.toml" ~/.config/starship.toml
link "$HOME_DIR/.config/tmux/tmux.conf" ~/.config/tmux/tmux.conf
link "$HOME_DIR/.config/helix/config.toml" ~/.config/helix/config.toml

if [ "$ROLE" = "pc" ]; then
    mkdir -p ~/.config/{ghostty,zed}
    mkdir -p "$HOME/Library/Application Support/com.mitchellh.ghostty"

    git config --global core.editor "zed --wait"

    link "$HOME_DIR/.config/ghostty/config" ~/.config/ghostty/config
    link "$HOME_DIR/.config/ghostty/config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
    link "$HOME_DIR/.config/zed/settings.json" ~/.config/zed/settings.json
else
    git config --global core.editor hx
fi

if [ "$ROLE" = "server" ]; then
    # --- Headless macOS system ---
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

    # Mount external disks without requiring a GUI user login.
    sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true

    # Normal OpenSSH over Tailscale. Tailscale provides private network access;
    # sshd still handles authentication.
    sudo systemsetup -setremotelogin on

    # Screen Sharing over Tailscale.
    sudo launchctl enable system/com.apple.screensharing
    sudo launchctl kickstart -k system/com.apple.screensharing

    # SMB File Sharing.
    sudo launchctl enable system/com.apple.smbd
    if ! sudo launchctl print system/com.apple.smbd >/dev/null 2>&1; then
        sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.smbd.plist
    fi
    sudo launchctl kickstart -k system/com.apple.smbd
fi

# Firewall.
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

if [ "$ROLE" = "pc" ]; then
    # FileVault requires the login password and returns a personal recovery key.
    if fdesetup isactive >/dev/null 2>&1; then
        echo "FileVault is already enabled."
    else
        echo "Enabling FileVault..."
        echo "Save the recovery key somewhere other than this Mac."
        sudo fdesetup enable -user "$(id -un)" -prompt
    fi
fi

echo
echo "$ROLE import complete."
if [ "$ROLE" = "server" ]; then
    echo "Manual steps remaining:"
    echo "  - System Settings > General > Sharing > Remote Login > Allow full disk access for remote users."
    echo "  - Configure File Sharing folders and users if needed; do not enable guest access."
    echo "  - One-time per data disk, if needed: sudo chown $(id -un):staff \"/Volumes/<volume>\""
    echo "  - Restart your terminal."
else
    echo "Manual steps remaining:"
    echo "  - Enable Lockdown Mode: System Settings > Privacy & Security > Lockdown Mode > Turn On & Restart."
    echo "  - If you postpone Lockdown Mode, restart your terminal manually."
fi
