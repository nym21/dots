#!/usr/bin/env bash
# shared/macos-update.sh, each mode, with fakes for sudo, softwareupdate,
# sw_vers, sleep, sudoers.sh and the workloads, which log what they are asked.
# shellcheck disable=SC2015 # run's lent password: written, or removed
source "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/repo/shared" "$TMP/repo/server" "$TMP/bin" "$TMP/home/.config/dots"
cp "$REPO/shared/macos-update.sh" "$REPO/shared/lent.sh" "$TMP/repo/shared/"
echo server > "$TMP/home/.config/dots/role"
calls="$TMP/calls"
cat > "$TMP/repo/shared/sudoers.sh" <<EOF
#!/bin/bash
echo "sudoers \$*" >> "$calls"
EOF
cat > "$TMP/repo/server/workloads.sh" <<EOF
#!/bin/bash
echo "workloads \$1" >> "$calls"
[ "\$1" != stop ] || [ -z "\${STOP_FAIL:-}" ] || exit 1
EOF
cat > "$TMP/bin/softwareupdate" <<EOF
#!/bin/bash
if [ "\$1" = --list ]; then printf '%s\n' "\$LIST"; exit 0; fi
password=''
for arg; do [ "\$arg" != --stdinpass ] || IFS= read -r password; done
echo "softwareupdate \$*\${password:+ with password \$password}" >> "$calls"
case " \$* " in
    *" --install macOS"*)
        [ -z "\${INSTALL_FAIL:-}" ] || exit 1
        [ -z "\${INSTALL_TERM:-}" ] || kill -TERM "\$(cat "$TMP/script.pid")"
        ;;
esac
exit 0
EOF
cat > "$TMP/bin/sudo" <<'EOF'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do case "$1" in -p) shift 2 ;; *) shift ;; esac; done
exec "$@"
EOF
printf '#!/bin/bash\necho 27.0.1\n' > "$TMP/bin/sw_vers"
printf '#!/bin/bash\n:\n' > "$TMP/bin/sleep"
chmod +x "$TMP"/bin/* "$TMP"/repo/shared/*.sh "$TMP"/repo/server/*.sh
minor=$'* Label: macOS 27.2-26B123\n\tTitle: macOS 27.2, Version: 27.2, Size: 1KiB, Recommended: YES, Action: restart,\n* Label: Safari 27.1-x\n\tTitle: Safari 27.1, Version: 27.1, Size: 1KiB, Recommended: YES,'
major=$'* Label: macOS Tahoe 28.0-x\n\tTitle: macOS Tahoe 28.0, Version: 28.0, Size: 1KiB, Recommended: YES, Action: restart,\n* Label: Safari 27.1-x\n\tTitle: Safari 27.1, Version: 27.1, Size: 1KiB, Recommended: YES,'
lent="$TMP/home/.config/dots/password"
marker="$TMP/home/.config/dots/macos-downloaded"

# Run it with ENV... and ARGS..., lent the password or not, its stdin no
# terminal; its output in $TMP/out.
run() {
    : > "$calls"
    rm -f "$marker"
    [ "$1" = lent ] && printf 'dummy-pw\n' > "$lent" || rm -f "$lent"
    shift
    (
        export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
        env "$@" > "$TMP/out" 2>&1 < /dev/null &
        echo $! > "$TMP/script.pid"
        wait $!
    )
}
called() {
    grep -q -- "$1" "$calls"
}
not_called() {
    ! grep -q -- "$1" "$calls"
}
# Whether the first call matching A came before the first matching B.
before() {
    local a b
    a="$(grep -n -- "$1" "$calls" | head -1 | cut -d: -f1)"
    b="$(grep -n -- "$2" "$calls" | head -1 | cut -d: -f1)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
said() {
    grep -q "$1" "$TMP/out"
}
script="$TMP/repo/shared/macos-update.sh"

run lent LIST="$minor" "$script" --download
check "a download, lent the password, passes it on its input" called 'softwareupdate --download macOS 27.2-26B123 --user .* --stdinpass with password dummy-pw'
check "and marks it downloaded" [ "$(cat "$marker")" = 27.2 ]
check "the lent password is deleted at once" [ ! -e "$lent" ]

run none LIST="$minor" "$script" --download
check "a download without it says so" said 'without the password'
check "and marks nothing" [ ! -e "$marker" ]

run lent LIST="$major" "$script" --download --same-major
check "with --same-major, a major upgrade waits" said 'a major upgrade, waits'
check "the other updates still install" called 'softwareupdate --install Safari'
check "but not the major upgrade" not_called 'macOS Tahoe'

run lent LIST="$minor" "$script"
check "an install stops the workloads before installing" before 'workloads stop' '--install macOS'
check "and starts them again when no restart came" called 'workloads start'

run lent LIST="$minor" INSTALL_FAIL=1 "$script"
check "a failed install starts the workloads again" called 'workloads start'

run lent LIST="$minor" STOP_FAIL=1 "$script"
check "a stop that fails partway starts them again" called 'workloads start'
check "and installs nothing" not_called '--install macOS'

run none LIST="$minor" "$script"
check "without a terminal or the password, it only says macOS is out" said 'is out'
check "and stops nothing" not_called 'workloads stop'

run lent LIST="$minor" INSTALL_TERM=1 "$script"
check "the shutdown's signal does not start the workloads" not_called 'workloads start'
finish
