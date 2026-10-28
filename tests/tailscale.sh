#!/usr/bin/env bash
# server/tailscale.sh --check and --update: moving Tailscale's daemon onto
# root's copy, and back should it not come back. Every system path points into
# the scratch directory, and sudo, install, launchctl and tailscale are fakes;
# the daemon comes back or not as COMES_BACK says.
# shellcheck disable=SC2016 # the stand-ins' own expansions, left for them
source "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/repo/server" "$TMP/repo/shared" "$TMP/bin" "$TMP/brew" "$TMP/libexec" \
    "$TMP/LaunchDaemons" "$TMP/home/.config/dots"
cp "$REPO/shared/lent.sh" "$TMP/repo/shared/"
printf '#!/bin/bash\n:\n' > "$TMP/repo/shared/sudoers.sh"
sed -e "s#/Library/LaunchDaemons/com.local.tailscaled.plist#$TMP/LaunchDaemons/com.local.tailscaled.plist#" \
    -e "s#/opt/homebrew/opt/tailscale/bin/tailscaled#$TMP/brew/tailscaled#" \
    -e "s#/opt/homebrew/opt/tailscale/bin/tailscale\"#$TMP/bin/tailscale\"#" \
    -e "s#/usr/local/libexec#$TMP/libexec#g" \
    -e 's#\[ "\$(stat -f .%Su. "\$1")" = root \] && .*#true#' \
    "$REPO/server/tailscale.sh" > "$TMP/repo/server/tailscale.sh"
cat > "$TMP/bin/sudo" <<'EOF'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do
    case "$1" in -S) IFS= read -r _ ;; -p) shift ;; esac
    shift
done
exec "$@"
EOF
cat > "$TMP/bin/install" <<'EOF'
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
    case "$1" in -o | -g) shift 2 ;; -d) mkdir -p "${@: -1}"; exit 0 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat > "$TMP/bin/launchctl" <<EOF
#!/bin/bash
case "\$1" in
    print) exit 1 ;;
    bootstrap | kickstart)
        echo "\$1" >> "$TMP/launchctl.calls"
        if [ "\$COMES_BACK" = yes ]; then echo Running > "$TMP/state"; else echo Stopped > "$TMP/state"; fi
        "\$(plutil -extract ProgramArguments.0 raw "$TMP/LaunchDaemons/com.local.tailscaled.plist")" --version > "$TMP/daemon" 2>/dev/null ||
            echo none > "$TMP/daemon"
        ;;
esac
EOF
cat > "$TMP/bin/tailscale" <<EOF
#!/bin/bash
case "\$*" in
    version) cat "$TMP/brew-version" ;;
    "version --daemon") echo "Client: x"; echo "Daemon: \$(cat "$TMP/daemon")-tabc" ;;
    "status --json") echo "{\"BackendState\": \"\$(cat "$TMP/state")\"}" ;;
esac
EOF
printf '#!/bin/bash\n:\n' > "$TMP/bin/sleep"
chmod +x "$TMP"/bin/* "$TMP/repo/server/tailscale.sh" "$TMP/repo/shared/sudoers.sh"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
script="$TMP/repo/server/tailscale.sh"
plist="$TMP/LaunchDaemons/com.local.tailscaled.plist"

# Homebrew's tailscaled of VERSION, running or not.
brew_binary() {
    printf '#!/bin/bash\n[ "$1" = --version ] && { echo %s; exit %s; }\n' "$1" "${2:-0}" > "$TMP/brew/tailscaled"
    chmod +x "$TMP/brew/tailscaled"
    echo "$1" > "$TMP/brew-version"
}
# The plist the minis had, which ran Homebrew's tailscaled.
old_plist() {
    sed "s#<string>$TMP/libexec/tailscaled</string>#<string>$TMP/brew/tailscaled</string>#" \
        <(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.tailscaled</string>

    <key>ProgramArguments</key>
    <array>
        <string>$TMP/libexec/tailscaled</string>
        <string>--no-logs-no-support</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
) > "$plist"
    rm -f "$TMP/libexec/tailscaled"
    echo Running > "$TMP/state"
    cat "$TMP/brew-version" > "$TMP/daemon"
}
lend() {
    printf 'dummy-pw\n' > "$TMP/home/.config/dots/password"
}
runs() {
    [ "$(plutil -extract ProgramArguments.0 raw "$plist")" = "$1" ]
}

brew_binary 1.104.4
old_plist
check "--check says a daemon on Homebrew's binary needs moving" fails "$script" --check
lend
COMES_BACK=yes "$script" --update > /dev/null
check "--update moves it onto root's copy" runs "$TMP/libexec/tailscaled"
check "which runs Homebrew's version" grep -qx 1.104.4 "$TMP/daemon"
check "and --check then passes" "$script" --check
check "the lent password is deleted" [ ! -e "$TMP/home/.config/dots/password" ]

brew_binary 1.106.0
: > "$TMP/launchctl.calls"
lend
COMES_BACK=yes "$script" --update > /dev/null
check "a Homebrew upgrade restarts the daemon on the new copy" grep -qx 1.106.0 "$TMP/daemon"
check "with a kickstart, its plist unchanged" grep -qx kickstart "$TMP/launchctl.calls"

: > "$TMP/launchctl.calls"
lend
COMES_BACK=yes "$script" --update > /dev/null
check "with nothing new, nothing restarts" [ ! -s "$TMP/launchctl.calls" ]

brew_binary 1.104.4
old_plist
lend
COMES_BACK=no "$script" --update > /dev/null 2>&1
check "a daemon that does not come back has its old plist put back" runs "$TMP/brew/tailscaled"

old_plist
lend
COMES_BACK=yes "$script" --update > /dev/null
brew_binary 1.108.0 1
: > "$TMP/launchctl.calls"
lend
check "a new binary that does not run fails the update" fails env COMES_BACK=yes "$script" --update
check "before the daemon is touched" [ ! -s "$TMP/launchctl.calls" ]
check "the copy it ran kept" grep -qx 1.104.4 <("$TMP/libexec/tailscaled" --version)
finish
