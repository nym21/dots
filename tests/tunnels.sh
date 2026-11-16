#!/usr/bin/env bash
# server/tunnels.sh: the workload taking its token file, set's leave and join,
# while serving and while waiting, one tunnel's crash, a stray cloudflared
# reaped, a start after a crash, and the transition log, with a
# stand-in cloudflared that only waits, and once told to stop, ends half a
# second later, as one finishing its last requests, and fakes for what else it
# asks of the mini.
# shellcheck disable=SC2016,SC2034,SC2086 # ON_EXIT, expanded when it runs; the list counted by its words
source "$(dirname "$0")/lib.sh"
if ! command -v cc >/dev/null; then
    echo "  skipped: no C compiler for the stand-in cloudflared"
    exit 0
fi
mkdir -p "$TMP/bin" "$TMP/server" "$TMP/home"
cp "$REPO/server/tunnels.sh" "$TMP/server/"
cat > "$TMP/cloudflared.c" <<'EOF'
#include <signal.h>
#include <unistd.h>
int main(void) {
    sigset_t term;
    int signal;
    sigemptyset(&term);
    sigaddset(&term, SIGTERM);
    sigprocmask(SIG_BLOCK, &term, 0);
    sigwait(&term, &signal);
    usleep(500000);
    return 0;
}
EOF
cc -o "$TMP/bin/cloudflared" "$TMP/cloudflared.c"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
case "${*: -1}" in
    */api/server/sync) printf '{"blocks_behind":0}\n200' ;;
    */ready) printf '{"status":200,"readyConnections":1}' ;;
esac
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/bin/bash
pid=''
while [ $# -gt 0 ]; do [ "$1" != -p ] || pid="$2"; shift; done
printf 'p%s\nf3\nn127.0.0.1:%s\n' "$pid" $((20000 + pid % 1000))
EOF
# The servers run unless $TMP/down exists.
cat > "$TMP/bin/pgrep" <<EOF
#!/bin/bash
case "\$*" in "-x bitcoind" | "-x bitviewd" | "-x bitview_mcp") [ ! -e "$TMP/down" ]; exit ;; esac
exec /usr/bin/pgrep "\$@"
EOF
# Only the stand-ins: this Mac's own cloudflared is not the test's.
printf '#!/bin/bash\nexec /usr/bin/pkill -f "%s/bin/cloudflared"\n' "$TMP" > "$TMP/bin/pkill"
printf '#!/bin/bash\necho %s\n' "'{\"Self\":{\"DNSName\":\"m4-1.tail.ts.net.\"}}'" > "$TMP/bin/tailscale"
chmod +x "$TMP"/bin/* "$TMP"/server/*.sh
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
script="$TMP/server/tunnels.sh"
log="$HOME/Library/Logs/dots/tunnels.log"
ON_EXIT='kill "$workload" 2>/dev/null; wait "$workload" 2>/dev/null'

tokens() {
    printf '%s\n' "$@"
}
# The workload's cloudflareds, and how many.
tunnels() {
    /usr/bin/pgrep -P "$workload" -x cloudflared | sort | tr '\n' ' '
}
count() {
    local list
    list="$(tunnels)"
    set -- $list
    echo "$#"
}
# Wait until COMMAND... holds, run anew each tenth of a second, for up to 15
# seconds.
until_true() {
    for _ in $(seq 1 150); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}
ready_count() {
    "$script" state | grep -c ' ready$'
}

check "set writes the token file while no workload runs" eval 'tokens "prod tok-prod" "mcp tok-mcp" "m4-1 tok-own" | "$script" set prod mcp m4-1'
"$TMP/bin/cloudflared" &
stray=$!
"$script" > "$TMP/workload.log" 2>&1 &
workload=$!
check "a cloudflared a killed workload left is stopped" until_true eval '! kill -0 "$stray" 2>/dev/null'
check "it starts a tunnel for each token" until_true eval '[ "$(count)" -eq 3 ]'
check "and says each is ready" until_true eval '[ "$(ready_count)" -eq 3 ]'
check "the log has each connected" until_true eval '[ "$(grep -c " connected$" "$log")" -eq 3 ]'
before="$(tunnels)"

check "set returns once the tunnels dropped have ended" eval 'tokens "m4-1 tok-own" | "$script" set m4-1'
check "only the own tunnel is left" [ "$(count)" -eq 1 ]
own="$(tunnels)"
own="${own% }"
check "the own tunnel keeps its process" contains "$before" "$own"
check "the log has prod lost" grep -q ' m4-1 prod lost$' "$log"

check "set returns once those gained are ready" eval 'tokens "prod tok-prod" "mcp tok-mcp" "m4-1 tok-own" | "$script" set prod mcp m4-1'
check "so all three are ready by then" [ "$(ready_count)" -eq 3 ]
check "a set missing a token fails" fails eval 'tokens "prod tok-prod" | "$script" set prod mcp m4-1'
check "and changes nothing" [ "$(wc -l < "$TMP/server/.tokens")" -eq 3 ]

prod="$(tunnels)"
kill -9 "$(/usr/bin/pgrep -n -P "$workload" -x cloudflared)"
check "a cloudflared that exits is lost alone" until_true eval '[ "$(ready_count)" -eq 2 ]'
kept="$(tunnels)"
set -- $kept
check "the others keep their processes" [ "$#" -eq 2 ] && contains "$prod" "$1" && contains "$prod" "$2"
check "it starts again 10 seconds later" until_true eval '[ "$(ready_count)" -eq 3 ]'

touch "$TMP/down"
check "with a server down, it waits" until_true eval '"$script" state | grep -qx waiting'
check "set returns once a drop is taken while waiting" eval 'tokens "m4-1 tok-own" | "$script" set m4-1 2>/dev/null'
check "which it has taken by then" [ "$("$script" state | tail -n +3 | xargs)" = "m4-1 lost" ]
rm "$TMP/down"

check "set to nothing" eval '"$script" set < /dev/null'
kill -9 "$workload"
wait "$workload" 2>/dev/null
touch -t 202611161200 "$HOME/.config/dots/running/tunnels"
"$script" >> "$TMP/workload.log" 2>&1 &
workload=$!
check "started after a crash, it logs all lost when the crash left its state" until_true grep -q '^2026-11-16T..:00:00Z m4-1 \* lost$' "$log"
sleep 2
check "and runs with no tunnel" kill -0 "$workload"

kill -TERM "$workload"
wait "$workload" 2>/dev/null
check "stopped, it stops its tunnels" fails /usr/bin/pgrep -f '^cloudflared tunnel run --protocol http2'

check "its state says only the token file's tunnels, none" [ "$("$script" state)" = "tokens " ]
finish
