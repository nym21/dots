#!/usr/bin/env bash
# pc/fleet's functions, taken from it, with ssh, the keychain, and the servers
# faked: what they record of their calls in $calls says what they did.
# shellcheck disable=SC2034,SC2088,SC2329 # pc/fleet's globals and stand-ins, which its code, taken here, uses
source "$(dirname "$0")/lib.sh"
fleet="$REPO/pc/fleet"
eval "$(sed -n '/^entries() {/,/^}/p; /^shared() {/,/^}/p; /^tunnels_of() {/,/^}/p; /^unheld() {/,/^}/p;
    /^check_password() {/,/^}/p; /^set_tokens() {/,/^}/p; /^detach() {/,/^}/p; /^follow_job() {/,/^}/p;
    /^kept_password() {/,/^}/p; /^check_passwords() {/,/^}/p; /^macos_note() {/,/^}/p;
    /^update_macos() {/,/^}/p; /^update_tailscaled() {/,/^}/p; /^others_serve() {/,/^}/p;
    /^serving() {/,/^}/p; /^connected() {/,/^}/p; /^needing_first() {/,/^}/p; /^hand_over() {/,/^}/p' "$fleet")"
work="$TMP/work" STATE_DIR="$TMP/state" CONF="$TMP/fleet.conf" TUNNELS="$TMP/tunnels"
mkdir -p "$work"
server_user=mini ready_timeout=43200 fetch_timeout=3600 incomplete='' MACOS_ARGS=''
SHIP=ship JOB=job TAILSCALE_SH=tailscale.sh TUNNELS_SH=tunnels.sh MACOS_UPDATE=macos-update.sh PASSWORD='~/pw'
printf 'm4-1 prod prod mcp\nm4-2 prod prod mcp\n' > "$CONF"
printf 'prod t\nmcp t\nm4-1 t\nm4-2 t\n' > "$TUNNELS"
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
# Whether the first call matching A came before the first matching B.
before() {
    local a b
    a="$(grep -n -- "$1" "$calls" | head -1 | cut -d: -f1)"
    b="$(grep -n -- "$2" "$calls" | head -1 | cut -d: -f1)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
sleep() {
    SECONDS=$((SECONDS + ${1%.*} + 1))
}

# check_password: what the server's answer means.
for pair in 0:0 9:1 255:2 1:2; do
    ssh_to() { cat > /dev/null; return "${pair%%:*}"; }
    check "a password check answered ${pair%%:*} means ${pair##*:}" status_is "${pair##*:}" check_password m4-1 pw
done

# set_tokens: a write that fails stops the run.
on() { echo differs; }
ssh_to() { cat > /dev/null; return 255; }
check "a token write that fails stops the run" fails eval '(set_tokens m4-1 prod m4-1) > /dev/null 2>&1'
on() { printf '%s\n' "prod t" | shasum; }
check "tokens it has already: status 1, nothing written" status_is 1 set_tokens m4-1 prod

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

# update_macos: what fetch said decides, and only while the others serve.
printf '%s\n' 'Could not download macOS 28.0 without the password, which fleet update lends.' \
    'macOS 28.0, a major upgrade, waits for fleet update run by hand.' > "$work/fetch.m4-1"
printf '%s\n' 'Could not download macOS 27.2 without the password, which fleet update lends.' \
    'macOS 27.2 is downloaded.' > "$work/fetch.m4-2"
printf 'm4-1\nm4-2\n' > "$work/checked"
lend_password() { record "lent $1"; }
detach() { record "job on $1: $2"; }
follow_job() { return 1; }
wait_serving() { record "waited for $1"; }
on() {
    case "$2" in
        *--check) return "${CHECK:-0}" ;;
        sw_vers*) echo 27.0.1 ;;
    esac
}
reset; update_macos m4-1 m4-1 2> /dev/null
check "a major upgrade waiting is not installed" fails called "job on m4-1"
reset; update_macos m4-2 m4-2 > /dev/null 2>&1
check "a downloaded update is installed, as a job" called "job on m4-2: macos-update.sh"
reset; CHECK=1 update_macos m4-2 m4-1 m4-2 2> /dev/null
check "not while a partner does not serve" fails called "job on m4-2"

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

# connected and needing_first: a server catching up still serves its tunnels.
on() { eval "return \${CHECK_${1//-/_}}"; }
CHECK_m4_1=3 CHECK_m4_2=1
check "a server catching up counts as connected" connected m4-1
check "a server down does not" fails connected m4-2
check "the one down goes first, the one catching up after" [ "$(needing_first m4-1 m4-2 | tr '\n' ' ')" = "m4-2 m4-1 " ]

# hand_over: the others join, then the last leaves at once, then the purge.
set_tokens() { record "tokens of $1: ${*:2}"; }
purge_for() { record "purged ${*:2}"; }
ssh_to() {
    local word
    IFS= read -r word || return 1
    record "$1 got '$word'"
    return "${LEAVE:-0}"
}
on() {
    case "$2" in
        *"reload --wait") record "$1 joined"; return 0 ;;
        *reload) record "$1 asked again"; return "${RETRY:-0}" ;;
    esac
}
reset; (hand_over m4-2 "prod mcp" m4-1 m4-2) > /dev/null
check "the last's token file drops the shared tunnels first" before "tokens of m4-2: m4-2" "m4-1 joined"
check "the others join before the last leaves" before "m4-1 joined" "m4-2 got 'go'"
check "the purge comes once it has left" before "m4-2 got 'go'" "purged prod mcp"
rm -f "$work/leave.m4-2"
reset; (LEAVE=255 hand_over m4-2 "prod mcp" m4-1 m4-2) > /dev/null
check "a lost connection has the word go again" called "m4-2 asked again"
check "and the hand-over completes" called "purged prod mcp"
rm -f "$work/leave.m4-2"
reset
check "a last server that never answers stops the run" fails eval '(LEAVE=255 RETRY=255 hand_over m4-2 "prod mcp" m4-1 m4-2) > /dev/null 2>&1'
check "without purging" fails called "purged"
finish
