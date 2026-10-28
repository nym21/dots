#!/usr/bin/env bash
set -euo pipefail

# Tailscale's daemon, as root, run from a copy of Homebrew's tailscaled that
# only root can change: Homebrew's own belongs to mini, so root running it
# would let anything running as mini become root.
#
#   tailscale.sh            set Tailscale up: Homebrew's, the daemon, its login
#   tailscale.sh --check    whether the daemon runs Homebrew's current
#                           tailscaled, as root's copy: status 0 when it does
#   tailscale.sh --update   bring it there, restarting the daemon only when that
#                           changes it, and back to what it ran should it not
#                           come back
#
# fleet update runs --update as a job of the server's own, lent the password,
# as the restart drops the connection over it; ship update in a terminal.

DOTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PLIST_DEST="/Library/LaunchDaemons/com.local.tailscaled.plist"
SERVICE="system/com.local.tailscaled"
TAILSCALE="/opt/homebrew/opt/tailscale/bin/tailscale"
TAILSCALED="/opt/homebrew/opt/tailscale/bin/tailscaled"
COPY="/usr/local/libexec/tailscaled"

mode=setup
case "$#:${1:-}" in
    0:) ;;
    1:--check) mode=check ;;
    1:--update) mode=update ;;
    *)
        echo "Usage: $0 [--check | --update]" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.tailscaled</string>

    <key>ProgramArguments</key>
    <array>
        <string>$COPY</string>
        <string>--no-logs-no-support</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
}

# Whether the daemon, from this plist, runs root's copy of Homebrew's
# tailscaled, of the version Homebrew's tailscale is.
current() {
    cmp -s "$(readlink -f "$TAILSCALED")" "$COPY" &&
        [ "$(plist)" = "$(cat "$PLIST_DEST" 2>/dev/null)" ] &&
        [ "$("$TAILSCALE" version | head -1)" = \
            "$("$TAILSCALE" version --daemon 2>/dev/null | sed -n 's/^Daemon: //p' | cut -d - -f 1)" ]
}

if [ "$mode" = check ]; then
    # 1 for any way it is not, as cmp's 2 for a copy not made yet.
    current || exit 1
    exit 0
fi

source "$DOTS_DIR/shared/lent.sh" ""

# Whether DIR only root can change: root's, and no one else may write in it.
root_only() {
    [ "$(stat -f '%Su' "$1")" = root ] && [ $(( 0$(stat -f '%Lp' "$1") & 022 )) -eq 0 ]
}

# Whether the daemon runs, within two minutes.
running() {
    local _
    for _ in {1..60}; do
        [ "$("$TAILSCALE" status --json 2>/dev/null | jq -r .BackendState 2>/dev/null)" = Running ] && return 0
        sleep 2
    done
    return 1
}

# Load the daemon from its plist again, once launchd has let the old one go.
reload() {
    local _
    as_root launchctl bootout "$SERVICE" 2>/dev/null || true
    for _ in {1..50}; do
        as_root launchctl print "$SERVICE" >/dev/null 2>&1 || break
        sleep 0.2
    done
    as_root launchctl enable "$SERVICE"
    as_root launchctl bootstrap system "$PLIST_DEST"
}

# The plist install_daemon replaced, for put_back.
previous_plist=''
trap 'rm -f "$previous_plist"' EXIT

# Install root's copy of Homebrew's tailscaled and the plist, keeping what
# they replace for put_back, then restart the daemon on them, loading it
# again only when the plist changed.
install_daemon() {
    local binary tmp
    binary="$(readlink -f "$TAILSCALED")"
    for dir in / /usr /usr/local; do
        if ! root_only "$dir"; then
            echo "$dir is not root's alone, so a copy of tailscaled there could change; leaving the daemon." >&2
            exit 1
        fi
    done
    [ -d /usr/local/libexec ] || as_root install -d -o root -g wheel -m 755 /usr/local/libexec
    if ! root_only /usr/local/libexec; then
        echo "/usr/local/libexec is not root's alone; leaving the daemon." >&2
        exit 1
    fi
    if [ -e "$COPY" ]; then
        as_root cp -p "$COPY" "$COPY.previous"
    fi
    as_root install -o root -g wheel -m 755 "$binary" "$COPY"
    # Before the daemon is touched, so a copy that does not run only goes.
    if ! as_root "$COPY" --version >/dev/null 2>&1; then
        echo "The copy of tailscaled does not run; leaving the daemon as it is." >&2
        if [ -e "$COPY.previous" ]; then
            as_root mv "$COPY.previous" "$COPY"
        else
            as_root rm -f "$COPY"
        fi
        exit 1
    fi
    tmp="$(mktemp)"
    plist > "$tmp"
    plutil -lint "$tmp" >/dev/null
    if [ "$(cat "$tmp")" != "$(cat "$PLIST_DEST" 2>/dev/null)" ]; then
        if [ -e "$PLIST_DEST" ]; then
            previous_plist="$(mktemp)"
            cp "$PLIST_DEST" "$previous_plist"
        fi
        as_root install -o root -g wheel -m 644 "$tmp" "$PLIST_DEST"
        rm -f "$tmp"
        reload
    else
        rm -f "$tmp"
        as_root launchctl kickstart -k "$SERVICE"
    fi
}

# Put back what install_daemon replaced, and restart the daemon on it.
put_back() {
    if [ -e "$COPY.previous" ]; then
        as_root mv "$COPY.previous" "$COPY"
    fi
    if [ -n "$previous_plist" ]; then
        as_root install -o root -g wheel -m 644 "$previous_plist" "$PLIST_DEST"
    fi
    reload
}

if [ "$mode" = update ]; then
    version="$("$TAILSCALE" version | head -1)"
    if current; then
        echo "Tailscale's daemon runs $version, as root's copy."
        exit 0
    fi
    # Without the rule that let mini restart the daemon, now root's alone.
    with_lent "$DOTS_DIR/shared/sudoers.sh"
    echo "Moving Tailscale's daemon onto $version, as root's copy..."
    install_daemon
    if ! running; then
        echo "Tailscale's daemon did not come back on $version; putting back what it ran." >&2
        put_back
        running || echo "It does not run on that either; see sudo launchctl print $SERVICE." >&2
        exit 1
    fi
    as_root rm -f "$COPY.previous"
    echo "Tailscale's daemon runs $version, as root's copy."
    exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Install Homebrew first." >&2
    exit 1
fi

GUI_CONFLICT=0

if brew list --cask tailscale-app >/dev/null 2>&1; then
    echo "Tailscale GUI conflict: Homebrew still records the tailscale-app cask." >&2
    GUI_CONFLICT=1
fi

if [ -d /Applications/Tailscale.app ]; then
    echo "Tailscale GUI conflict: /Applications/Tailscale.app still exists." >&2
    GUI_CONFLICT=1
fi

if pgrep -f io.tailscale.ipn.macsys.network-extension >/dev/null 2>&1; then
    echo "Tailscale GUI conflict: the system extension is still running:" >&2
    pgrep -lf io.tailscale.ipn.macsys.network-extension >&2 || true
    GUI_CONFLICT=1
fi

if [ "$GUI_CONFLICT" -ne 0 ]; then
    echo "Remove the reported GUI component and reboot before installing tailscaled." >&2
    exit 1
fi

brew install tailscale
"$DOTS_DIR/shared/sudoers.sh"
install_daemon

for _ in {1..40}; do
    [ -S /var/run/tailscaled.socket ] && break
    sleep 0.25
done

if [ ! -S /var/run/tailscaled.socket ]; then
    echo "tailscaled did not create its socket." >&2
    sudo launchctl print "$SERVICE" >&2
    exit 1
fi

as_root rm -f "$COPY.previous"
sudo "$TAILSCALE" up
sudo "$TAILSCALE" status
