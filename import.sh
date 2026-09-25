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

if [ "$ROLE" = "server" ]; then
    sudo -v
    # Probe an actual read: file mode checks do not establish Full Disk Access.
    # sudo handles Unix permissions; macOS privacy checks still apply.
    if ! sudo /bin/dd if="/Library/Application Support/com.apple.TCC/TCC.db" \
        of=/dev/null bs=1 count=1 >/dev/null 2>&1; then
        echo "Cannot verify Full Disk Access. Server setup has not started." >&2
        echo "Local terminal: System Settings > Privacy & Security > Full Disk Access." >&2
        echo "  Enable your terminal app, then quit and reopen it." >&2
        echo "SSH: System Settings > General > Sharing > Remote Login > Info." >&2
        echo "  Enable Allow full disk access for remote users, then reconnect." >&2
        exit 1
    fi
fi

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$DOTS_DIR/home"

mkdir -p "$HOME/Developer"

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
brew bundle install --file="$DOTS_DIR/Brewfile"
if [ "$ROLE" = "pc" ]; then
    echo "Installing and updating Homebrew casks..."
    brew bundle install --file="$DOTS_DIR/Brewfile.cask"

    # Configure Raycast before launch so it cannot cache the default opt-ins.
    echo "Disabling Raycast analytics and error reporting..."
    pkill -x Raycast 2>/dev/null || true
    defaults write com.raycast.macos analytics_optOut -bool true
    defaults write com.raycast.macos errorReporting_optOut -bool true
else
    echo "Installing and updating server tools..."
    brew bundle install --file="$DOTS_DIR/Brewfile.server"
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
    [ -n "$pkg" ] || continue
    echo "Installing ${pkg}..."
    cargo install --locked "$pkg"
done < "$DOTS_DIR/cargo.txt"

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
mkdir -p ~/.config/{fish,tmux,helix} ~/.local/bin

git config --global diff.external difft
git config --global core.editor hx

link "$DOTS_DIR/tssh" ~/.local/bin/tssh
link "$HOME_DIR/.config/fish/config.fish" ~/.config/fish/config.fish
link "$HOME_DIR/.config/starship.toml" ~/.config/starship.toml
link "$HOME_DIR/.config/tmux/tmux.conf" ~/.config/tmux/tmux.conf
link "$HOME_DIR/.config/tmux/save-layout.sh" ~/.config/tmux/save-layout.sh
link "$HOME_DIR/.config/tmux/restore-layout.sh" ~/.config/tmux/restore-layout.sh
link "$HOME_DIR/.config/helix/config.toml" ~/.config/helix/config.toml

if [ "$ROLE" = "pc" ]; then
    mkdir -p ~/.config/zed
    git config --global core.editor "zed --wait"
    link "$HOME_DIR/.config/zed/settings.json" ~/.config/zed/settings.json
fi

if [ "$ROLE" = "server" ]; then
    SERVER_USER="$(id -un)"

    if ! id -Gn "$SERVER_USER" | tr ' ' '\n' | grep -qx admin; then
        echo "Server user '$SERVER_USER' must be an administrator for full-volume file sharing." >&2
        exit 1
    fi

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
    mdutil -a -s

    # Keep the machine reachable while allowing the display to sleep.
    sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1

    # Disable unused sharing features through their supported controls.
    sudo systemsetup -setremoteappleevents off
    CONTENT_CACHE_STATUS="$(AssetCacheManagerUtil -j status)"
    CONTENT_CACHE_ACTIVATED="$(plutil -extract result.Activated raw -expect bool - <<< "$CONTENT_CACHE_STATUS")"
    if [ "$CONTENT_CACHE_ACTIVATED" = true ]; then
        sudo AssetCacheManagerUtil deactivate
    else
        echo "Content Caching is already disabled."
    fi
    sudo cupsctl -h /private/var/run/cupsd --no-share-printers

    # Mount external disks without requiring a GUI user login.
    sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true

    # Every non-system volume attached to this server is a server-owned data disk.
    # Claim only the volume root; preserve ownership within existing contents.
    for volume in /Volumes/*; do
        [ -d "$volume" ] && [ ! -L "$volume" ] || continue
        [ "$(basename "$volume")" = "Macintosh HD" ] && continue
        echo "Setting ownership of '$volume' to $SERVER_USER:staff..."
        sudo chown "$SERVER_USER:staff" "$volume"
    done

    # Normal OpenSSH over Tailscale. Tailscale provides private network access;
    # sshd still handles authentication.
    sudo systemsetup -setremotelogin on

    # Keep Screen Sharing and SMB available on demand, without restarting
    # active connections when the import is rerun.
    sudo sysadminctl -smbGuestAccess off
    for service in com.apple.screensharing com.apple.smbd; do
        sudo launchctl enable "system/$service"
        if ! sudo launchctl print "system/$service" >/dev/null 2>&1; then
            sudo launchctl bootstrap system "/System/Library/LaunchDaemons/$service.plist"
        fi
    done

    # Disable unused wireless radios. Refuse to turn off the server's active
    # network path so a remote import cannot strand the machine.
    WIFI_DEVICE="$(
        networksetup -listallhardwareports |
            awk '
                $0 == "Hardware Port: Wi-Fi" || $0 == "Hardware Port: AirPort" {
                    getline
                    sub(/^Device: /, "")
                    print
                    exit
                }
            '
    )"
    if [ -n "$WIFI_DEVICE" ]; then
        DEFAULT_ROUTE="$(route -n get default)"
        DEFAULT_INTERFACE="$(awk '$1 == "interface:" { print $2; exit }' <<< "$DEFAULT_ROUTE")"
        if [ -z "$DEFAULT_INTERFACE" ] || [ "$DEFAULT_INTERFACE" = "$WIFI_DEVICE" ]; then
            echo "Refusing to disable Wi-Fi: no other default network interface was confirmed." >&2
            echo "Connect and verify Ethernet, then run the server import again." >&2
            exit 1
        fi

        sudo networksetup -setairportpower "$WIFI_DEVICE" off
        echo "Wi-Fi: $(networksetup -getairportpower "$WIFI_DEVICE")"
    else
        echo "Skipping Wi-Fi: no wireless interface was found." >&2
    fi

    blueutil --power off
    echo "Bluetooth power: $(blueutil --power)"
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
    echo "Running the read-only server audit..."
    "$DOTS_DIR/server-audit.sh" || echo "Server audit failed; rerun $DOTS_DIR/server-audit.sh to investigate." >&2

    # macOS requires approval in System Settings to install local profiles.
    SERVER_PROFILE="$DOTS_DIR/server.mobileconfig"
    PROFILE_IDENTIFIER="$(plutil -extract PayloadIdentifier raw "$SERVER_PROFILE")"
    PROFILE_INSTALLED=false
    if sudo profiles list -type configuration | awk -v identifier="$PROFILE_IDENTIFIER" '
        $3 == "profileIdentifier:" && $4 == identifier { found = 1 }
        END { exit !found }
    '; then
        PROFILE_INSTALLED=true
    elif [ -z "${SSH_CONNECTION:-}" ]; then
        open "$SERVER_PROFILE" || echo "Open $SERVER_PROFILE manually to review and install it." >&2
    fi

    echo
    if [ "$PROFILE_INSTALLED" = false ]; then
        echo "Remaining in System Settings:"
        echo "  - General > Device Management: install the server profile."
        echo "    Open $SERVER_PROFILE on this Mac first if it is not listed."
    else
        echo "Server profile is already installed."
    fi
    echo "Optional cleanup: $DOTS_DIR/SERVER.md"
    echo "Then log out of the desktop."
else
    echo "Manual steps remaining:"
    echo "  - Enable Lockdown Mode: System Settings > Privacy & Security > Lockdown Mode > Turn On & Restart."
    echo "  - If you postpone Lockdown Mode, restart your terminal manually."
fi
