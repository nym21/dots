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

# Cloudflare's cf, which Bun installs and runs in place of Node, newest first,
# with its telemetry off for this Mac, as it would otherwise collect it and
# say so on every run.
install_cf() {
    bun add -g --silent cf@latest
    # By its path, as setup's PATH may not have ~/.local/bin yet.
    CF_QUIET=1 "$SHARED_DIR/../pc/cf" cli telemetry disable --quiet >/dev/null ||
        echo "Could not turn cf's telemetry off; run cf cli telemetry disable." >&2
}

# cargo-hawk, from Astral's installer, as Cargo cannot build it: each release
# is built against one stable Rust, so a Rust update needs its newest.
update_cargo_hawk() {
    local latest
    latest="$(curl -fsS -m 20 https://api.github.com/repos/astral-sh/hawk/releases/latest | jq -r .tag_name)" ||
        return 0
    [ "$(cargo hawk --version 2>/dev/null | awk '{ print $3 }')" != "$latest" ] || return 0
    echo "Installing cargo-hawk $latest..."
    curl -fsSL https://github.com/astral-sh/hawk/releases/latest/download/cargo-hawk-installer.sh |
        sh -s -- --quiet --no-modify-path
}

# The name of Time Machine's backup disk, as it last knew it. Empty without one.
backup_name() {
    defaults read /Library/Preferences/com.apple.TimeMachine Destinations 2>/dev/null |
        sed -nE 's/^ *LastKnownVolumeName = "?([^";]+)"?;$/\1/p' | head -1
}

# The volume of the backup disk named NAME, locked or not, when it is in.
backup_volume() {
    diskutil apfs list -plist | plutil -convert json -o - - |
        jq -r --arg name "$1" '.Containers[].Volumes[] | select(.Name == $name) | .DeviceIdentifier' | head -1
}

# When this Mac's last Time Machine backup completed, as Time Machine's
# settings list it, so a locked or missing backup disk does not matter. Empty
# without one.
last_backup() {
    defaults read /Library/Preferences/com.apple.TimeMachine Destinations 2>/dev/null | awk '
        /SnapshotDates/ { inside = 1; next }
        inside && /\)/ { inside = 0 }
        inside { gsub(/[",]/, ""); sub(/^ +/, ""); if ($0 != "") print }' | sort | tail -1
}

# Whether this Mac's last Time Machine backup is missing or over a week old.
# Its backups run by hand, automatic ones being off, as they keep snapshots on
# the local disk while the backup disk is away.
backup_problem() {
    local last
    last="$(last_backup)"
    if [ -z "$last" ]; then
        echo "Time Machine has completed no backup"
    elif [ "$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$last" +%s 2>/dev/null || echo 0)" -lt "$(date -v-7d +%s)" ]; then
        echo "Time Machine's last backup is from ${last%% *}, over a week ago"
    fi
}

# What only you can do on the workstation, one line each, while it is missing:
# setup ends with it, and ship status shows it.
missing_steps() {
    local app problem hosts server last missing='' tunnel='' password='' forward=''
    [ "$(defaults read .GlobalPreferences LDMGlobalEnabled 2>/dev/null)" = 1 ] ||
        echo "Turn on Lockdown Mode: System Settings > Privacy & Security > Lockdown Mode, then restart."
    # Each output read whole, as grep -q leaving early, or ssh -T failing even
    # when it logs in, would fail a pipeline.
    grep -q '^Mullvad account:' <<< "$(mullvad account get 2>/dev/null)" ||
        echo "Log in to Mullvad VPN: mullvad account login."
    grep -q 'successfully authenticated' <<< "$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1)" ||
        echo "Give GitHub an SSH key: ssh-keygen -t ed25519, then add ~/.ssh/id_ed25519.pub at https://github.com/settings/keys."
    ls -d /Applications/Rex*.app >/dev/null 2>&1 ||
        echo "Install the Rex app."
    # From the App Store, which Homebrew cannot check without Spotlight's index.
    for app in "AdGuard for Safari" "Blackmagic Disk Speed Test" Developer "Numbers Creator Studio" \
        "Pages Creator Studio" Xcode; do
        [ -d "/Applications/$app.app" ] || echo "Install $app from the App Store."
    done
    problem="$(backup_problem)"
    [ -z "$problem" ] || echo "$problem: put the backup disk in and run ship backup."
    # What fleet init gives, each part checked without changing it; a password
    # only for being kept, unread, as fleet update checks that it still works.
    # With no input, tssh waits for no login, which fleet init asks for.
    [ "$(tssh --tailscale status --json 2>/dev/null </dev/null | jq -r .BackendState)" = Running ] ||
        missing="$missing, the tailnet's login"
    jq -e .authenticated <<< "$(cf auth whoami 2>/dev/null)" >/dev/null 2>&1 ||
        missing="$missing, Cloudflare's login"
    hosts="$(rex hosts list --json 2>/dev/null | jq -r '.hosts[]?.host.label' 2>/dev/null || true)"
    for server in $(awk '!/^#/ && NF { print $1 }' "$SHARED_DIR/../pc/fleet.conf"); do
        awk -v name="$server" '$1 == name { found = 1 } END { exit !found }' "$SHARED_DIR/../pc/.tunnels" 2>/dev/null ||
            tunnel=1
        security find-generic-password -s "dots fleet $server" >/dev/null 2>&1 || password=1
        grep -qx "$server" <<< "$hosts" || forward=1
    done
    [ -z "$tunnel" ] || missing="$missing, a server's own tunnel"
    [ -z "$password" ] || missing="$missing, a server's password"
    [ -z "$forward" ] || missing="$missing, the Rex app's forward to a server"
    [ -z "$missing" ] || echo "Run fleet init; missing: ${missing#, }."
    last="$(cat "$FLEET_AUTO_STAMP" 2>/dev/null || date +%s)"
    if [ $(($(date +%s) - last)) -gt $((3 * 86400)) ]; then
        echo "fleet auto has not completed a fleet update for over 3 days: leave this Mac on power, with the servers in reach; ~/Library/Logs/fleet-auto.log says why."
    fi
}

# When a fleet update that fleet auto ran last succeeded.
FLEET_AUTO_STAMP="$HOME/Library/Application Support/dots/fleet-auto"

# fleet auto, as a LaunchAgent that runs it, and so fleet update, hourly.
install_fleet_auto() {
    local label=com.local.fleet-auto plist="$HOME/Library/LaunchAgents/com.local.fleet-auto.plist" tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/fleet</string>
        <string>auto</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/fleet-auto.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/fleet-auto.log</string>
</dict>
</plist>
PLIST
    if cmp -s "$tmp" "$plist"; then
        rm -f "$tmp"
        return 0
    fi
    # Reloading the agent would end a run of fleet's, mid-update.
    if kill -0 "$(cat "$HOME/Library/Application Support/dots/fleet.lock/pid" 2>/dev/null)" 2>/dev/null; then
        rm -f "$tmp"
        echo "fleet runs, so its LaunchAgent changes at the next ship update."
        return 0
    fi
    mkdir -p "$(dirname "$plist")"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    mv "$tmp" "$plist"
    launchctl bootstrap "gui/$(id -u)" "$plist"
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
