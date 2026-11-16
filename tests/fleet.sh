#!/usr/bin/env bash
# pc/fleet's functions, taken from it, with ssh, the keychain, and the servers
# faked: what they record of their calls in $calls says what they did.
# shellcheck disable=SC2034,SC2088,SC2218,SC2329 # pc/fleet's globals and functions, taken by eval, and stand-ins
source "$(dirname "$0")/lib.sh"
fleet="$REPO/pc/fleet"
eval "$(sed -n '/^check_password() {/,/^}/p; /^detach() {/,/^}/p;
    /^follow_job() {/,/^}/p; /^kept_password() {/,/^}/p; /^check_passwords() {/,/^}/p; /^macos_note() {/,/^}/p;
    /^update_macos() {/,/^}/p; /^update_tailscaled() {/,/^}/p' "$fleet")"
work="$TMP/work" STATE_DIR="$TMP/state"
mkdir -p "$work"
server_user=mini ready_timeout=43200 fetch_timeout=3600 incomplete=''
SHIP=ship JOB=job TAILSCALE_SH=tailscale.sh MACOS_UPDATE=macos-update.sh PASSWORD='~/pw'
calls="$TMP/calls"
record() {
    echo "$*" >> "$calls"
}
reset() {
    : > "$calls"
    incomplete=''
}
called() {
    grep -q -- "$1" "$calls"
}
sleep() {
    SECONDS=$((SECONDS + ${1%.*} + 1))
}

# check_password: what the server's answer means.
for pair in 0:0 9:1 255:2 1:2; do
    ssh_to() { cat > /dev/null; return "${pair%%:*}"; }
    check "a password check answered ${pair%%:*} means ${pair##*:}" status_is "${pair##*:}" check_password m4-1 pw
done

# detach: one job at a time.
tries=0
on() { tries=$((tries + 1)); [ "$tries" -ge 3 ] && return 0 || return 3; }
check "a job waits for an earlier one, then starts" eval 'detach m4-1 "ship apply" > /dev/null'
on() { return 3; }
SECONDS=0
check "and gives up after 12 hours" fails eval 'detach m4-1 "ship apply" > /dev/null 2>&1'

# follow_job: how long a server may go unanswered.
on() { return 255; }
SECONDS=0
follow_job m4-1 "$fetch_timeout" 2> /dev/null
check "while readying, a server unanswered for an hour is let go" [ "$SECONDS" -ge 3600 ] && [ "$SECONDS" -lt 7200 ]
SECONDS=0
follow_job m4-1 2> /dev/null
check "otherwise after 12 hours" [ "$SECONDS" -ge 43200 ]
unset -f sleep

# check_passwords: a refused password is not tried again until it changes.
keychain_password() { echo dummy; }
keychain_changed() { echo "$CHANGED"; }
check_password() { record "checked $1"; return "$ANSWER"; }
on() { return 0; }
reset; CHANGED=0xA ANSWER=1 check_passwords m4-1 2> /dev/null
check "a refused password is tried once" called "checked m4-1"
reset; CHANGED=0xA ANSWER=1 check_passwords m4-1 2> /dev/null
check "and not again while the keychain keeps it" fails called "checked m4-1"
check "the run still ends failing" [ -n "$incomplete" ]
reset; CHANGED=0xB ANSWER=0 check_passwords m4-1 2> /dev/null
check "once fleet init keeps another, it is tried" called "checked m4-1"
check "and works" grep -qx m4-1 "$work/checked"
reset; keychain_password() { :; }; CHANGED='' ANSWER=0 check_passwords m4-1 2> /dev/null
check "no password kept makes no attempt" fails called "checked m4-1"

# update_macos: installs what fetch downloaded, as a job.
echo 'macOS 27.0.1 and its other software are up to date.' > "$work/fetch.m4-1"
printf '%s\n' 'Could not download macOS 27.2 without the password, which fleet update lends.' \
    'macOS 27.2 is downloaded.' > "$work/fetch.m4-2"
printf 'm4-1\nm4-2\n' > "$work/checked"
lend_password() { record "lent $1"; }
detach() { record "job on $1: $2"; }
follow_job() { return 1; }
wait_serving() { record "waited for $1"; }
on() {
    case "$2" in
        sw_vers*) echo 27.0.1 ;;
    esac
}
reset; update_macos m4-2 > /dev/null 2>&1
check "a downloaded update is installed, as a job" called "job on m4-2: macos-update.sh"

# update_tailscaled: only when the daemon is not on root's copy.
for code in 0 255; do
    on() { return "$code"; }
    reset; update_tailscaled m4-1 > /dev/null
    check "--check answering $code moves nothing" fails called "job on"
done
on() { return 1; }
follow_job() { return 0; }
reset; update_tailscaled m4-1 > /dev/null
check "--check answering 1 moves the daemon, as a job" called "job on m4-1: tailscale.sh --update"
follow_job() { return 1; }
check "and a move that fails stops the run" fails eval '(update_tailscaled m4-1) > /dev/null 2>&1'

finish
