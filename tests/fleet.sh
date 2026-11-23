#!/usr/bin/env bash
# pc/fleet's functions, taken from it, with ssh, the keychain, and the servers
# faked: what they record of their calls in $calls says what they did.
# shellcheck disable=SC2034,SC2088,SC2218,SC2329 # pc/fleet's globals and functions, taken by eval, and stand-ins
source "$(dirname "$0")/lib.sh"
fleet="$REPO/pc/fleet"
eval "$(sed -n '/^check_password() {/,/^}/p; /^detach() {/,/^}/p;
    /^follow_job() {/,/^}/p; /^kept_password() {/,/^}/p; /^check_passwords() {/,/^}/p; /^macos_note() {/,/^}/p;
    /^update_macos() {/,/^}/p; /^update_tailscaled() {/,/^}/p;
    /^alert() {/,/^}/p; /^overdue() {/,/^}/p; /^recovered() {/,/^}/p' "$fleet")"
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

# A skipped update's alert: once per streak, which only a success ends, and
# again then. Each row is a run of its own, as launchd starts one each hour,
# so a restart mid-streak (nothing kept in memory) and a rotated log (never
# read) change nothing.
notify() { record "notify $1"; }
notified() { grep -c "^notify $1" "$calls"; }
last_success() { echo $(($(date +%s) - $1)) > "$STATE_DIR/fleet-auto"; }
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; reset
last_success 3600
(overdue "dots has uncommitted changes") > /dev/null
check "a skip an hour after a success notifies none" [ "$(notified fleet)" -eq 0 ]
last_success 7300
(HOME="$TMP/no-log" overdue "dots has uncommitted changes") > /dev/null
check "a skip past 2 hours notifies once" [ "$(notified 'fleet update skipped')" -eq 1 ]
(overdue "dots has uncommitted changes") > /dev/null
check "and the next hour's skip, in a new run, notifies none again" [ "$(notified 'fleet update skipped')" -eq 1 ]
(alert serve.m6-1 "fleet: m6-1 does not serve") > /dev/null
(alert serve.m6-1 "fleet: m6-1 does not serve") > /dev/null
check "a server's alert notifies once, apart from the skip's" [ "$(notified 'fleet: m6-1')" -eq 1 ]
(recovered) > /dev/null
check "a success after the streak notifies it runs again" [ "$(notified 'fleet update runs again')" -eq 1 ]
(recovered) > /dev/null
check "and a success without a streak notifies none" [ "$(notified 'fleet update runs again')" -eq 1 ]
last_success 7300
(overdue "dots's main is not origin's") > /dev/null
check "a new streak notifies again" [ "$(notified 'fleet update skipped')" -eq 2 ]
reset; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
(alert serve.m6-1 "fleet: m6-1 does not serve") > /dev/null
last_success 7300
(overdue "dots has uncommitted changes") > /dev/null
check "a server's alert never hides a skip streak" [ "$(notified 'fleet update skipped')" -eq 1 ]


# The whole of pc/fleet, end to end, against a model of the four minis: a fake
# ssh answers for them from $SIM/m/NAME, and appends to $SIM/events, at each
# change of the tunnels a serving mini runs, who serves each, at which version.
# KILL_AT and KILL_WHEN stop the run's process group at a selected change.
export SIM="$TMP/sim"
EVENTS="$SIM/events"
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat > "$FAKES/tailscale" <<'EOF'
#!/bin/bash
for d in "$SIM"/m/*; do printf '%s\n' "${d##*/}"; done |
    jq -Rn '{Peer: [inputs | {key: ., value: {OS: "macOS", DNSName: (. + ".ts.net.")}}] | from_entries}'
EOF
cat > "$FAKES/ssh" <<'EOF'
#!/bin/bash
set -u
while [ "$1" = -o ]; do shift 2; done
host="${1#*@}"
shift
cmd="$*" M="$SIM/m/$host"
[ -d "$M" ] && [ ! -e "$M/unreachable" ] || exit 255
get() { cat "$M/$1" 2>/dev/null; }
names() { get "$1" | sort | xargs; }
changed() {
    local line="$host: $1" t d n
    for t in prod next; do
        line="$line | $t:"
        for d in "$SIM"/m/*; do
            [ "$(cat "$d/down")" != 0 ] || ! grep -qx "$t" "$d/applied" || line="$line ${d##*/}@$(cat "$d/running")"
        done
    done
    echo "$line" >> "$SIM/events"
    for d in "$SIM"/m/*; do
        [ "$(cat "$d/down")" != 0 ] || grep -qx "${d##*/}" "$d/applied" || echo "$host: ${d##*/}" >> "$SIM/own_lost"
    done
    n=$(($(cat "$SIM/changes" 2>/dev/null || echo 0) + 1))
    echo "$n" > "$SIM/changes"
    if [ "$n" = "${KILL_AT:-}" ] || { [ -n "${KILL_WHEN:-}" ] && [[ "$line" =~ $KILL_WHEN ]]; }; then
        kill -9 -- -"$(cat "$SIM/pgid")"
        exit 255
    fi
}
pending() {
    { [ "$(get running)" = "$(get installed)" ] && [ "$(get running_mode)" = "$(cut -d ' ' -f 1 "$M/mode")" ] &&
        cmp -s "$M/cache_running" "$M/cache_installed" || echo bitviewd
      [ "$(get cf_running)" = "$(get cf_installed)" ] && [ ! -e "$M/old" ] || echo tunnels; } | xargs
}
restart() {
    get installed > "$M/running"
    cut -d ' ' -f 1 "$M/mode" > "$M/running_mode"
    get cache_installed > "$M/cache_running"
    get cf_installed > "$M/cf_running"
    rm -f "$M/old"
    get tokens > "$M/applied"
    echo "${RECOMPUTE:-2}" > "$M/down"
    changed restart
}
case "$cmd" in
    *"tunnels.sh state")
        # (Builtins only: fleet asks it most.)
        states=0 fail=''
        [ ! -e "$M/states" ] || read -r states < "$M/states"
        echo $((states += 1)) > "$M/states"
        [ ! -e "$M/fail_state" ] || read -r fail < "$M/fail_state"
        [ "$states" != "$fail" ] || exit 255
        read -r running < "$M/running"
        read -r down < "$M/down"
        read -r mode < "$M/running_mode"
        read -r cache < "$M/cache_running"
        if [ -e "$M/missing-record" ]; then
            rm "$M/missing-record"
        else
            printf 'mode %s\nbitviewd v0.1.0 (https://x/mono?rev=%s#x):\ncache %s\n' "$mode" "$running" "$cache"
        fi
        read -r job < "$M/job" || job=''
        echo "job $job"
        tokens='' applied=''
        while read -r t; do tokens="$tokens $t"; done 2> /dev/null < "$M/tokens"
        while read -r t; do applied="$applied $t"; done < "$M/applied"
        echo "tokens${tokens}"
        # A workload from before tunnels.sh's state: ready while it runs them all.
        if [ -e "$M/old" ]; then
            [ "$down" != 0 ] || [ "$tokens" != "$applied" ] || for t in $tokens; do echo "$t ready"; done
        elif [ "$down" = 0 ]; then
            echo serving
            for t in $applied; do echo "$t ready"; done
        else
            echo waiting
            for t in $applied; do echo "$t lost"; done
        fi
        ;;
    *"tunnels.sh set"*)
        set -- ${cmd#*tunnels.sh set}
        got="$(cat)"
        for n; do grep -q "^$n " <<< "$got" || exit 1; done
        before="$(names applied)"
        printf '%s\n' "$@" | grep . > "$M/tokens"
        get tokens > "$M/applied" # an old workload too: set has it reload (USR1)
        [ "$before" = "$(names applied)" ] || changed "set $*"
        ;;
    *"ship apply --pending") pending ;;
    *"ship status --check")
        d="$(get down)"
        [ "$d" -gt 0 ] || exit 0
        echo $((d - 1)) > "$M/down"
        [ "$d" -eq 1 ] || exit 1
        changed "serving again"
        ;;
    *"job.sh start "*)
        echo 0 > "$M/job"
        case "$cmd" in
            *"ship fetch"*)
                # The mode and its pin, recorded once it built.
                echo "$host" >> "$SIM/fetched"
                if [ -e "$M/fetch_fails" ]; then
                    echo 1 > "$M/job"
                else
                    args="${cmd#*ship fetch }"
                    echo "${args%\'}" > "$M/mode"
                    read -r _ pin _ < "$M/mode"
                    echo "$pin" > "$M/installed"
                    cat "$SIM/cf_version" > "$M/cf_installed"
                    if [ -e "$M/restart-on-fetch" ]; then echo "$pin" > "$M/running"; fi
                fi
                ;;
            *"ship apply"*) [ -z "$(pending)" ] || restart ;;
            *"ship stop && "*) restart ;;
        esac
        ;;
    *"job.sh status") get job ;;
    *"> ~/.config/dots/public-url'")
        sed -E "s/.*echo (.*) > ~\/\.config\/dots\/public-url'/\1/" <<< "$cmd" > "$M/public-url"
        ;;
    "git -C ~/Developer/dots pull -q --ff-only" | "tail -n +"* | *"tailscale.sh --check" | "rm -f ~/.config/dots/password") ;;
    *"ship status") echo "$(cut -d ' ' -f 1 "$M/mode") $(get running)" ;;
    *password* | *"sudo -S"*) cat > /dev/null ;;
    *) echo "fake ssh: $host: $cmd" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/bash\n[ "$1" != ls-remote ] || printf "%%s\\trefs/heads/x\\n" "$(cat "$SIM/pin.${3#refs/heads/}")"\n' > "$FAKES/git"
cat > "$FAKES/cf" <<'EOF'
#!/bin/bash
case "$1 $2" in
    'auth whoami') echo '{"authenticated":true}' ;;
    'tunnels list') echo '[]' ;;
    'tunnels config')
        if [ -e "$SIM/empty-ingress.${4#id-}" ]; then
            echo '{"config":{"ingress":[{"service":"http_status:404"}]}}'
        else
            printf '{"config":{"ingress":[{"hostname":"%s.invalid"}]}}\n' "${4#id-}"
        fi
        ;;
    'cache purge')
        while [ "$1" != --body ]; do shift; done
        tunnel="$(jq -er '.hosts[0] | rtrimstr(".invalid")' <<< "$2")" || exit 1
        echo "$tunnel" >> "$SIM/purges"
        [ ! -e "$SIM/fail-purge.$tunnel" ] || exit 1
        states="$(for holder in "$SIM"/m/*; do
            if [ "$(cat "$holder/down")" = 0 ] && grep -qx "$tunnel" "$holder/applied"; then
                paste "$holder/running" "$holder/cache_running"
            fi
        done | sort -u)"
        [ "$(wc -l <<< "$states")" -eq 1 ] || echo "$tunnel" >> "$SIM/premature-purges"
        echo '{"id":"fixture"}'
        ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/bash\necho %s >&2\n' "'password: \"pw\"'" > "$FAKES/security"
printf '#!/bin/bash\n' > "$FAKES/sleep"
chmod +x "$FAKES"/*


# The four minis in fleet.conf's two groups: a (m4-1 m6-1) serving prod at
# PROD, b (m4-2 m6-2) serving next at NEXT, each with its role's tunnels and
# its own.
sim_setup() {
    rm -rf "$SIM"
    mkdir -p "$SIM/pc" "$SIM/home"
    cp "$REPO/pc/fleet" "$REPO/pc/fleet.conf" "$SIM/pc/"
    for name in prod next m4-1 m4-2 m6-1 m6-2; do
        echo "$name $(printf '{"t":"id-%s"}' "$name" | base64)"
    done > "$SIM/pc/.tunnels"
    echo cf1 > "$SIM/cf_version"
    echo "$1" > "$SIM/pin.prod"
    echo "$2" > "$SIM/pin.next"
    sim_mini m4-1 prod "$1" prod
    sim_mini m6-1 prod "$1" prod
    sim_mini m4-2 next "$2" next
    sim_mini m6-2 next "$2" next
    : > "$SIM/events"
    : > "$SIM/purges"
    : > "$SIM/fetched"
    rm -f "$SIM/changes"
}
# SERVER in MODE, running VERSION, serving TUNNEL... and its own.
sim_mini() {
    local server="$1" mode="$2" version="$3" m="$SIM/m/$1"
    shift 3
    mkdir -p "$m"
    echo "$mode $version" > "$m/mode"
    echo "$mode" > "$m/running_mode"
    echo "$version" | tee "$m/installed" > "$m/running"
    echo default | tee "$m/cache_installed" > "$m/cache_running"
    echo cf1 | tee "$m/cf_installed" > "$m/cf_running"
    echo 0 | tee "$m/down" > "$m/job"
    printf '%s\n' "$@" "$server" | tee "$m/tokens" > "$m/applied"
}
# Run fleet ARGS... as a process group of its own.
sim_fleet() {
    local status=0
    set -m
    PATH="$FAKES:$PATH" HOME="$SIM/home" "$SIM/pc/fleet" "$@" > "$SIM/out" 2>&1 &
    echo "$!" > "$SIM/pgid"
    wait "$!" || status=$?
    set +m
    return "$status"
}
# Whether every snapshot kept prod at two servers and next at one.
sim_floors() {
    awk -F ' [|] ' '{ for (i = 2; i <= NF; i++) { split($i, f, ":"); if (split(f[2], h, " ") < (f[1] == "next" ? 1 : 2)) bad = 1 } }
        END { exit bad }' "$SIM/events"
}
# Whether the servers of group PROD serve prod at prod's pin, and the
# others next at NEXT, each serving and with its own tunnel.
sim_final() {
    local prod="$1" next="$2" group servers server want version
    while read -r _ group servers; do
        for server in $servers; do
            if [ "$group" = "$prod" ]; then want=prod version="$(cat "$SIM/pin.prod")"; else want=next version="$next"; fi
            [ "$(printf '%s\n' $want "$server" | sort | xargs)" = "$(sort "$SIM/m/$server/applied" | xargs)" ] &&
                [ "$(cat "$SIM/m/$server/running")" = "$version" ] &&
                [ "$(cat "$SIM/m/$server/down")" = 0 ] && [ ! -e "$SIM/m/$server/old" ] || return 1
        done
    done < <(grep '^group ' "$SIM/pc/fleet.conf")
}
# Whether no server of group a (m4-1 m6-1) built in any run since setup.
sim_a_built_nothing() {
    ! grep -qxE 'm4-1|m6-1' "$SIM/fetched"
}
sim_soak_over() {
    mkdir -p "$SIM/home/Library/Application Support/dots"
    echo $(($(date +%s) - 3 * 3600)) > "$SIM/home/Library/Application Support/dots/swapped"
}

# Next moves: the next group builds and restarts in turn, prod untouched.
sim_setup P0 N0
echo N1 > "$SIM/pin.next"
check "next's new commit reaches the next group" eval 'sim_fleet update && sim_final a N1'
check "with the floors kept throughout" sim_floors
check "the prod group building nothing and serving prod throughout" eval \
    'sim_a_built_nothing && ! grep -q "prod:[^|]*m[46]-2@" "$EVENTS"'
check "each server's Bitview gets its own address, the next group's here" \
    diff <(printf 'https://%s.bitview.space\n' m4-2 m6-2) <(cat "$SIM"/m/m4-2/public-url "$SIM"/m/m6-2/public-url)
check "each mini keeping its own tunnel except while it restarts" [ ! -e "$SIM/own_lost" ]

# A promotion of what next runs: a swap, nothing built.
sim_setup P0 N1
echo N1 > "$SIM/pin.prod"
check "prod's branch moved to what the next group runs swaps the groups" eval 'sim_fleet update && sim_final b P0'
check "with nothing built anywhere, the group that left prod keeping its version (the soak)" \
    eval '[ ! -s "$SIM/fetched" ] && grep -q "keeps what it runs" "$SIM/out"'
check "and the floors kept throughout" sim_floors
check "prod's cache purged once, after the swap" eval \
    '[ "$(grep -cx prod "$SIM/purges")" = 1 ] && [ ! -e "$SIM/premature-purges" ]'
check "fleet role names the new roles" eval \
    'sim_fleet role && [ "$(sort "$SIM/out" | xargs)" = "m4-1 next m4-2 prod m6-1 next m6-2 prod" ]'
echo N2 > "$SIM/pin.next"
check "next moving within the soak builds nothing" eval 'sim_fleet update && [ ! -s "$SIM/fetched" ] && sim_final b P0'
echo P0 > "$SIM/pin.prod"
check "prod pushed back within the soak swaps back at once, nothing built" eval \
    'sim_fleet update && sim_final a N1 && [ ! -s "$SIM/fetched" ] && sim_floors'
echo N1 > "$SIM/pin.prod"
sim_fleet update
sim_soak_over
: > "$SIM/fetched"
check "after the soak, the group that left prod builds next's newest" eval \
    'sim_fleet update && sim_final b N2 && [ "$(sort -u "$SIM/fetched" | xargs)" = "m4-1 m6-1" ] && sim_floors'

# A promotion of a commit next does not run: the next group builds it first,
# serving next only, then takes prod in the same run.
sim_setup P0 N0
echo C1 > "$SIM/pin.prod"
echo N1 > "$SIM/pin.next"
mkdir -p "$SIM/home/Developer/mono/scripts" "$SIM/home/Library/Application Support/dots"
printf '#!/bin/bash\necho "$1 $2" >> "$SIM/announced"\n' > "$SIM/home/Developer/mono/scripts/indexnow.sh"
chmod +x "$SIM/home/Developer/mono/scripts/indexnow.sh"
echo P0 > "$SIM/home/Library/Application Support/dots/indexnow-prod"
check "prod moved past next: the next group builds prod's commit, then takes prod" eval \
    'sim_fleet update && sim_final b P0 && sim_floors && sim_a_built_nothing'
check "IndexNow told once, of the old prod commit to the new, after the swap" \
    [ "$(cat "$SIM/announced")" = "P0 C1" ]
total="$(cat "$SIM/changes")"
for at in $(seq 1 "$total"); do
    (
        SIM="$TMP/sim.$at"
        sim_setup P0 N0
        echo C1 > "$SIM/pin.prod"
        echo N1 > "$SIM/pin.next"
        KILL_AT="$at" sim_fleet update
        rm -f "$SIM/changes"
        sim_fleet update && sim_floors && sim_final b P0 && sim_a_built_nothing &&
            [ "$(grep -cx prod "$SIM/purges")" -ge 1 ] && [ ! -e "$SIM/premature-purges" ] || echo "$at" >> "$TMP/broken"
    ) 2> /dev/null &
    [ $((at % 8)) -ne 0 ] || wait
done
wait
check "killed after any of its $total changes (mid-build, mid-swap), a rerun ends the same, floors kept, prod purged" \
    [ ! -e "$TMP/broken" ]

# A build that fails leaves prod where it is, and IndexNow untold.
sim_setup P0 N0
echo C1 > "$SIM/pin.prod"
touch "$SIM/m/m6-2/fetch_fails"
check "a next server whose build fails keeps the swap from happening" eval \
    '! sim_fleet update && grep -qx prod "$SIM/m/m4-1/applied" && grep -qx prod "$SIM/m/m6-1/applied" &&
     ! grep -qx prod "$SIM/m/m4-2/applied" && sim_floors'

# A prod server gone: the next group builds prod's commit and takes prod.
sim_setup P0 N0
touch "$SIM/m/m6-1/unreachable"
check "a prod server that does not answer has the next group build prod's commit and take prod" eval \
    '! sim_fleet update && grep -qx prod "$SIM/m/m4-2/applied" && grep -qx prod "$SIM/m/m6-2/applied" &&
     [ "$(cat "$SIM/m/m4-2/running")" = P0 ] && ! grep -qx prod "$SIM/m/m4-1/applied" && sim_floors'

# A next server gone: no swap, prod untouched, the run fails.
sim_setup P0 N1
echo N1 > "$SIM/pin.prod"
touch "$SIM/m/m6-2/unreachable"
check "a next server that does not answer keeps its group off prod, and the run fails" eval \
    '! sim_fleet update && grep -qx prod "$SIM/m/m4-1/applied" && grep -qx prod "$SIM/m/m6-1/applied" &&
     ! grep -qx prod "$SIM/m/m4-2/applied" && sim_floors'

# A job of fleet's still running on a next server (an earlier run's build).
sim_setup P0 N1
echo N1 > "$SIM/pin.prod"
echo > "$SIM/m/m4-2/job"
check "a next server with a job running takes no prod" eval \
    'sim_fleet tunnels && grep -qx prod "$SIM/m/m4-1/applied" && ! grep -qx prod "$SIM/m/m4-2/applied"'
echo 0 > "$SIM/m/m4-2/job"
check "and once it ends, fleet tunnels swaps" eval 'sim_fleet tunnels && sim_final b P0 && sim_floors'

# A hold for timed work on a next server.
sim_setup P0 N1
echo N1 > "$SIM/pin.prod"
mkdir -p "$SIM/home/Developer/brain/bin"
printf '#!/bin/bash\ncase "$1" in status) echo "held: bench since 2026-11-23T09:08:14Z (9 min)" ;; take) echo "$2" >> "$SIM/takes"; exit 75 ;; esac\n' \
    > "$SIM/home/Developer/brain/bin/m6-2-lock"
chmod +x "$SIM/home/Developer/brain/bin/m6-2-lock"
check "a held next server keeps its group off prod, untouched" eval \
    'sim_fleet update && grep -qx prod "$SIM/m/m4-1/applied" && ! grep -qx m6-2 "$SIM/fetched" && sim_floors'
echo N2 > "$SIM/pin.next"
echo P0 > "$SIM/pin.prod"
check "and fleet auto's run that would build on it waits for its lock, then stops with status 4" eval \
    'FLEET_AUTO=1 status_is 4 sim_fleet update && grep -qx fleet-auto "$SIM/takes" && ! grep -qx m6-2 "$SIM/fetched"'
check "while a run by hand, as the holder's, builds on it" eval \
    'rm -f "$SIM/takes" && sim_fleet update m6-2 && grep -qx m6-2 "$SIM/fetched" && [ ! -e "$SIM/takes" ]'

# Prod never restarts.
sim_setup P0 N0
check "a prod server is never restarted: its tunnels would fall below their floor" eval \
    '! sim_fleet restart m4-1 && grep -q "below its floor of 2" "$SIM/out" && [ ! -s "$EVENTS" ]'
check "a next server restarts, the other keeping next" eval \
    'sim_fleet restart m4-2 && sim_floors && sim_final a N0'

sim_setup P0 N0
first=m4-1
touch "$SIM/m/$first/unreachable"
check "an unobserved holder blocks only its tunnels from purging" eval \
    'status_is 1 sim_fleet tunnels && grep -q "Skipping the cache purge of prod" "$SIM/out" &&
     ! grep -qx prod "$SIM/purges" && grep -qx next "$SIM/purges"'

broken=''
for at in 1 2 3 4 5 6; do
    sim_setup P0 N0
    echo N1 > "$SIM/pin.next"
    echo "$at" > "$SIM/m/m6-2/fail_state"
    sim_fleet update
    sim_floors && sim_fleet update && sim_final a N1 || broken="$broken $at"
done
check "a mini that does not answer a probe keeps its tunnels, and a rerun ends right" [ -z "$broken" ]

sim_setup P0 N0
rm "$SIM/m/m6-2/tokens" "$SIM/m/m6-2/applied"
touch "$SIM/m/m6-2/applied"
check "a new mini gets its tunnels and its own" eval 'sim_fleet update && sim_final a N0'

sim_setup P0 N0
for server in m4-2 m6-2; do touch "$SIM/m/$server/old"; done
sim_fleet update
check "the next group's workloads from before tunnels.sh's state restart in turn, within two runs" eval \
    'sim_floors && { sim_final a N0 || { sim_fleet update && sim_floors && sim_final a N0; }; }'

# A next mini whose build failed takes its tunnels back on its old build.
sim_setup P0 N0
echo N1 > "$SIM/pin.next"
touch "$SIM/m/m4-2/fetch_fails"
sim_fleet update
rm "$SIM/m/m4-2/fetch_fails"
check "a mini whose fetch failed, restarted, takes its tunnels back on its old build" eval \
    'sim_fleet restart m4-2 && sim_floors && grep -qx next "$SIM/m/m4-2/applied"'

# A cache-affecting change on the next group purges next, at the same build.
sim_setup P0 N0
sim_fleet update
: > "$SIM/purges"
for server in m4-2 m6-2; do echo changed > "$SIM/m/$server/cache_installed"; done
check "a flag change on the next group restarts it and purges next alone" eval \
    'sim_fleet update && [ "$(sort -u "$SIM/purges" | xargs)" = "m4-2 m6-2 next" ] && [ ! -e "$SIM/premature-purges" ]'

finish
