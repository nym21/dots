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


# The whole of pc/fleet, end to end, against a model of the four minis: a fake
# ssh answers for them from $SIM/m/NAME, and appends to $SIM/events, at each
# change of the tunnels a serving mini runs, who serves each, at which version.
# With KILL_AT, the Kth change kills the run, its whole process group.
export SIM="$TMP/sim"
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
    for t in prod mcp next; do
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
    [ "$n" != "${KILL_AT:-}" ] || { kill -9 -- -"$(cat "$SIM/pgid")"; exit 255; }
}
pending() {
    { [ "$(get running)" = "$(get installed)" ] && [ "$(get running_mode)" = "$(cut -d ' ' -f 1 "$M/mode")" ] || echo bitviewd
      [ "$(get cf_running)" = "$(get cf_installed)" ] && [ ! -e "$M/old" ] || echo tunnels; } | xargs
}
restart() {
    get installed > "$M/running"
    cut -d ' ' -f 1 "$M/mode" > "$M/running_mode"
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
        echo "mode $mode"
        echo "bitviewd v0.1.0 (https://x/mono?rev=$running#x):"
        echo "mode $mode"
        echo "bitview_mcp v0.1.0 (https://x/mono?rev=$running#x):"
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
                # The mode and its pins, recorded once they built.
                if [ -e "$M/fetch_fails" ]; then
                    echo 1 > "$M/job"
                else
                    args="${cmd#*ship fetch }"
                    echo "${args%\'}" > "$M/mode"
                    read -r _ pin _ < "$M/mode"
                    echo "$pin" > "$M/installed"
                    cat "$SIM/cf_version" > "$M/cf_installed"
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
printf '#!/bin/bash\ncase "$*" in "auth whoami"*) echo %s ;; "tunnels config get"*) echo %s ;; esac\n' \
    "'{\"authenticated\":true}'" "'{\"config\":{\"ingress\":[{\"hostname\":\"h\"}]}}'" > "$FAKES/cf"
printf '#!/bin/bash\necho %s >&2\n' "'password: \"pw\"'" > "$FAKES/security"
printf '#!/bin/bash\n' > "$FAKES/sleep"
chmod +x "$FAKES"/*

# The four minis as fleet.conf has them, at PROD and NEXT, the versions of
# their modes, each serving the tunnels it gives them.
sim_setup() {
    rm -rf "$SIM"
    mkdir -p "$SIM/pc" "$SIM/home"
    cp "$REPO/pc/fleet" "$SIM/pc/"
    printf '%s\n' 'm4-1 prod prod mcp' 'm4-2 prod prod mcp' 'm6-1 prod prod mcp' 'm6-2 next next' > "$SIM/pc/fleet.conf"
    for name in prod mcp next m4-1 m4-2 m6-1 m6-2; do
        echo "$name $(printf '{"t":"id-%s"}' "$name" | base64)"
    done > "$SIM/pc/.tunnels"
    echo cf1 > "$SIM/cf_version"
    echo "$1" > "$SIM/pin.prod"
    echo "$2" > "$SIM/pin.next"
    while read -r server mode tunnels; do
        m="$SIM/m/$server"
        mkdir -p "$m"
        echo "$mode $(cat "$SIM/pin.$mode") $(cat "$SIM/pin.$mode")" > "$m/mode"
        echo "$mode" > "$m/running_mode"
        tee "$m/installed" < "$SIM/pin.$mode" > "$m/running"
        echo cf1 | tee "$m/cf_installed" > "$m/cf_running"
        echo 0 | tee "$m/down" > "$m/job"
        printf '%s\n' $tunnels "$server" | tee "$m/tokens" > "$m/applied"
    done < "$SIM/pc/fleet.conf"
    : > "$SIM/events"
    rm -f "$SIM/changes"
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
# Whether every snapshot kept prod and mcp at two servers and next at one.
sim_floors() {
    awk -F ' [|] ' '{ for (i = 2; i <= NF; i++) { split($i, f, ":"); if (split(f[2], h, " ") < (f[1] == "next" ? 1 : 2)) bad = 1 } }
        END { exit bad }' "$SIM/events"
}
# Whether every mini runs what fleet.conf gives it, at its mode's version.
sim_final() {
    local server mode tunnels
    while read -r server mode tunnels; do
        [ "$(printf '%s\n' $tunnels "$server" | sort | xargs)" = "$(sort "$SIM/m/$server/applied" | xargs)" ] &&
            [ "$(cat "$SIM/m/$server/running")" = "$(cat "$SIM/pin.$mode")" ] &&
            [ "$(cat "$SIM/m/$server/down")" = 0 ] && [ ! -e "$SIM/m/$server/old" ] || return 1
    done < "$SIM/pc/fleet.conf"
}

sim_setup P0 N0
echo P1 > "$SIM/pin.prod"
echo N1 > "$SIM/pin.next"
check "a version change of prod and next ends as fleet.conf says" sim_fleet update
check "with the floors kept throughout" sim_floors
check "prod rolling one mini at a time, m6-2 never lent" fails grep -q 'prod:[^|]* m6-2@' "$SIM/events"
check "each mini keeping its own tunnel except while it restarts" [ ! -e "$SIM/own_lost" ]
check "each server's Bitview gets its own address" \
    diff <(for m in "$SIM"/m/*; do echo "https://${m##*/}.bitview.space"; done) <(cat "$SIM"/m/*/public-url)
total="$(cat "$SIM/changes")"
# (Eight at a time, each in its own model.)
for at in $(seq 1 "$total"); do
    (
        SIM="$TMP/sim.$at"
        sim_setup P0 N0
        echo P1 > "$SIM/pin.prod"
        echo N1 > "$SIM/pin.next"
        KILL_AT="$at" sim_fleet update
        rm -f "$SIM/changes"
        sim_fleet update && sim_floors && sim_final || echo "$at" >> "$TMP/broken"
    ) 2> /dev/null &
    [ $((at % 8)) -ne 0 ] || wait
done
wait
check "killed after any of its $total changes, a rerun ends the same, with the floors kept" [ ! -e "$TMP/broken" ]

sim_setup P0 N0
echo P1 > "$SIM/pin.prod"
echo 1 > "$SIM/m/m6-1/down"
check "with only two prod holders ready, neither can restart" eval \
    '! sim_fleet update m4-1 m4-2 && grep -q "below its floor of 2" "$SIM/out" && [ ! -s "$SIM/events" ]'

sim_setup P0 N0
for server in m4-1 m4-2 m6-1; do echo next | tee -a "$SIM/m/$server/tokens" >> "$SIM/m/$server/applied"; done
printf 'm6-2\n' | tee "$SIM/m/m6-2/tokens" > "$SIM/m/m6-2/applied"
check "fleet tunnels hands next back to m6-2 across modes" eval 'sim_fleet tunnels && sim_floors && sim_final'

broken=''
for at in 1 2 3 4 5 6; do
    sim_setup P0 N0
    echo N1 > "$SIM/pin.next"
    echo "$at" > "$SIM/m/m6-2/fail_state"
    sim_fleet update
    sim_floors && sim_fleet update && sim_final || broken="$broken $at"
done
check "a mini that does not answer a probe keeps its tunnels, and a rerun ends right" [ -z "$broken" ]

sim_setup P0 N0
rm "$SIM/m/m6-2/tokens" "$SIM/m/m6-2/applied"
touch "$SIM/m/m6-2/applied"
check "a new mini gets its tunnels and its own" eval 'sim_fleet update && sim_final'

sim_setup P0 N0
for server in "$SIM"/m/*; do touch "$server/old"; done
sim_fleet update
check "the workloads from before tunnels.sh's state restart in turn, behind the floors, within two runs" eval \
    'sim_floors && { sim_final || { sim_fleet update && sim_floors && sim_final; }; }'

# A mini whose build failed keeps the mode of what it runs, so restarted it
# takes its tunnels back.
sim_setup P0 N0
echo P1 > "$SIM/pin.prod"
touch "$SIM/m/m4-1/fetch_fails"
sim_fleet update
rm "$SIM/m/m4-1/fetch_fails"
check "a mini whose fetch failed, restarted, takes its tunnels back on its old build" eval \
    'sim_fleet restart m4-1 && sim_floors && grep -qx prod "$SIM/m/m4-1/applied" && grep -qx mcp "$SIM/m/m4-1/applied"'

# m6-2 given prod in fleet.conf, but not yet updated to it.
sim_setup P0 N0
printf '%s\n' 'm4-1 prod prod mcp' 'm4-2 prod prod mcp' 'm6-1 prod prod mcp' 'm6-2 prod prod mcp next' > "$SIM/pc/fleet.conf"
check "a mini moved to another mode takes none of its tunnels before it is updated" eval \
    '! sim_fleet tunnels && sim_floors && ! grep -qx prod "$SIM/m/m6-2/applied"'

finish
