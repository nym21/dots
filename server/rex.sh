#!/usr/bin/env bash
set -euo pipefail

# Install or update the Rex server from Rex's update feed and run it at boot
# as a LaunchDaemon under this user, so it works at the login screen.
# The feed is not public: its URL stays out of Git in server/.rex-feed.

SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"
FEED_FILE="$SERVER_DIR/.rex-feed"
# The Developer ID team that signs Rex.
TEAM_ID="AG92C3PT77"
SERVER_USER="$(id -un)"
BUNDLE="$HOME/Applications/Rex Server.app"
REX="$BUNDLE/Contents/MacOS/rex"
LOG="$HOME/Library/Logs/rex-server.log"
LABEL="com.local.rex"
PLIST_DEST="/Library/LaunchDaemons/$LABEL.plist"
SERVICE="system/$LABEL"

# --yes restarts the server without asking, as dots update does.
YES=0
case "$#:${1:-}" in
    0:) ;;
    1:--yes) YES=1 ;;
    *)
        echo "Usage: $0 [--yes]" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the target login user, not with sudo." >&2
    exit 1
fi

# Inside a Rex terminal this names that terminal's server; talk to the
# daemon's default socket instead.
unset REX_SERVER

FEED=''
if [ -r "$FEED_FILE" ]; then
    while IFS=$' \t\r' read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        FEED="$line"
        break
    done < "$FEED_FILE"
fi
if [ -z "$FEED" ]; then
    echo "Missing the Rex feed URL in $FEED_FILE; see server/README.md." >&2
    exit 1
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
MOUNTED=0

detach() {
    hdiutil detach -quiet "$MOUNT" || hdiutil detach -force -quiet "$MOUNT"
    MOUNTED=0
}

cleanup() {
    trap - EXIT HUP INT TERM
    if [ "$MOUNTED" -eq 1 ] && ! detach; then
        echo "Could not detach $MOUNT; leaving $WORK in place." >&2
        return
    fi
    rm -rf "$WORK"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

server_status() {
    "$REX" --autostart=false server status 2>/dev/null || true
}

status_field() {
    awk -v key="$1:" '$1 == key { print $2; exit }'
}

# --- Download the newest build when it is not installed ---
curl -fsSL --proto '=https' -o "$WORK/feed.xml" "$FEED"

LATEST=0
URL=''
COUNT="$(xmllint --xpath 'count(/rss/channel/item)' "$WORK/feed.xml")"
for ((i = 1; i <= COUNT; i++)); do
    build="$(xmllint --xpath "string(/rss/channel/item[$i]/*[local-name()='version'])" "$WORK/feed.xml")"
    case "$build" in
        ''|*[!0-9]*) continue ;;
    esac
    if [ "$build" -gt "$LATEST" ]; then
        LATEST="$build"
        URL="$(xmllint --xpath "string(/rss/channel/item[$i]/enclosure/@url)" "$WORK/feed.xml")"
    fi
done
if [ -z "$URL" ]; then
    echo "The Rex feed lists no build to download." >&2
    exit 1
fi

INSTALLED=''
if [ -f "$BUNDLE/Contents/Info.plist" ]; then
    INSTALLED="$(plutil -extract CFBundleVersion raw "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
fi

if [ "$INSTALLED" = "$LATEST" ]; then
    echo "Rex build $LATEST is already installed."
else
    echo "Downloading Rex build $LATEST..."
    curl -fL --proto '=https' --progress-bar -o "$WORK/rex.dmg" "$URL"

    mkdir "$MOUNT"
    hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$MOUNT" "$WORK/rex.dmg" </dev/null
    MOUNTED=1

    # The app carries the server as a helper and installs it as an app of its own.
    helper=''
    for app in "$MOUNT"/*.app; do
        if [ -d "$app/Contents/Helpers/Rex Server.rex" ]; then
            helper="$app/Contents/Helpers/Rex Server.rex"
            break
        fi
    done
    if [ -z "$helper" ]; then
        echo "The downloaded disk image contains no Rex server." >&2
        exit 1
    fi
    ditto "$helper" "$WORK/Rex Server.app"
    detach

    codesign --verify --strict \
        -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
        "$WORK/Rex Server.app"

    # Swap by renaming, so a running server keeps its original files.
    mkdir -p "$(dirname "$BUNDLE")"
    rm -rf "$BUNDLE.old"
    if [ -e "$BUNDLE" ]; then
        mv "$BUNDLE" "$BUNDLE.old"
    fi
    mv "$WORK/Rex Server.app" "$BUNDLE"
    rm -rf "$BUNDLE.old"
    echo "Installed Rex build $LATEST in $BUNDLE."
fi

mkdir -p "$HOME/.local/bin"
if [ -L "$HOME/.local/bin/rex" ] || [ ! -e "$HOME/.local/bin/rex" ]; then
    ln -sfn "$REX" "$HOME/.local/bin/rex"
else
    echo "Leaving $HOME/.local/bin/rex alone: it is not a link." >&2
fi

# --- LaunchDaemon ---
USER_SHELL="$(dscl . -read "/Users/$SERVER_USER" UserShell | awk '{ print $2 }')"
mkdir -p "$(dirname "$LOG")"

PLIST_TMP="$WORK/$LABEL.plist"
cat > "$PLIST_TMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>UserName</key>
    <string>$SERVER_USER</string>

    <key>ProgramArguments</key>
    <array>
        <string>$REX</string>
        <string>server</string>
        <string>run</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>USER</key>
        <string>$SERVER_USER</string>
        <key>LOGNAME</key>
        <string>$SERVER_USER</string>
        <key>SHELL</key>
        <string>$USER_SHELL</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>$HOME</string>

    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_TMP" >/dev/null

# Restart only when the daemon is missing, its settings changed, or it runs
# another build than the one installed.
RESTART=0
if ! sudo launchctl print "$SERVICE" >/dev/null 2>&1; then
    RESTART=1
elif ! cmp -s "$PLIST_TMP" "$PLIST_DEST"; then
    RESTART=1
else
    running="$(server_status | status_field version)"
    if [ "$running" != "$("$REX" version | awk 'NR == 1 { print $2 }')" ]; then
        RESTART=1
    fi
fi

WORKLOADS=0
if [ "$RESTART" -eq 1 ] && sudo launchctl print "$SERVICE" >/dev/null 2>&1; then
    sessions="$(server_status | status_field sessions)"
    case "$sessions" in
        ''|*[!0-9]*) sessions=0 ;;
    esac
    # A terminal of this server, this script's own, would end halfway. The
    # new build is installed and runs from the next restart.
    if [ -n "${REX_BLOCK:-}" ]; then
        echo "Rex is updated, but restarting the server would end this terminal; run this over SSH to restart it."
        exit 0
    fi
    # Sessions and the programs running in them end with the server.
    if [ "$sessions" -gt 0 ] && [ "$YES" -eq 0 ]; then
        answer=''
        if [ -t 0 ]; then
            read -r -p "Restarting the Rex server ends its $sessions session(s); the workloads stop cleanly first and start again after. Restart now? [y/N] " answer
        fi
        case "$answer" in
            [yY]*) ;;
            *)
                echo "Not restarted. Run this script again to restart the Rex server."
                exit 0
                ;;
        esac
    fi
    # The server would end the workloads abruptly, Bitcoin Core mid-write.
    if "$REX" --autostart=false ls --json 2>/dev/null |
        jq -e '.sessions[] | select(.label == "server")' >/dev/null; then
        WORKLOADS=1
        "$SERVER_DIR/workloads.sh" stop
    fi
    sudo launchctl bootout "$SERVICE"
fi

if [ "$RESTART" -eq 1 ]; then
    sudo install -o root -g wheel -m 644 "$PLIST_TMP" "$PLIST_DEST"
    sudo launchctl enable "$SERVICE"
    sudo launchctl bootstrap system "$PLIST_DEST"
fi

# --- Check the daemon answers ---
for _ in {1..40}; do
    status="$(server_status)"
    [ -n "$status" ] && break
    sleep 0.25
done
if [ -z "$status" ]; then
    echo "The Rex server did not answer. Log: $LOG" >&2
    exit 1
fi

daemon_pid="$(sudo launchctl print "$SERVICE" 2>/dev/null | awk '$1 == "pid" { print $3; exit }')"
if [ "$(status_field pid <<< "$status")" != "$daemon_pid" ]; then
    echo "Another Rex server holds the socket (pid $(status_field pid <<< "$status"))." >&2
    echo "Stop it with: rex server stop, then run this script again." >&2
    exit 1
fi

echo "Rex server $(status_field version <<< "$status") is running as $SERVICE."

if [ "$WORKLOADS" -eq 1 ]; then
    "$SERVER_DIR/workloads.sh" boot
fi
