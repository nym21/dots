#!/usr/bin/env bash
# server/tunnels.sh: a reload's leave and join, with a stand-in cloudflared
# that only waits, and once told to stop, ends half a second later, as one
# finishing its last requests, and fakes for what else it asks of the mini.
# shellcheck disable=SC2016,SC2034,SC2086 # ON_EXIT, expanded when it runs; the list counted by its words
source "$(dirname "$0")/lib.sh"
if ! command -v cc >/dev/null; then
    echo "  skipped: no C compiler for the stand-in cloudflared"
    exit 0
fi
mkdir -p "$TMP/bin" "$TMP/server" "$TMP/home"
cp "$REPO/server/tunnels.sh" "$TMP/server/"
printf '#!/bin/bash\necho "$*" >> "%s/workloads.calls"\n' "$TMP" > "$TMP/server/workloads.sh"
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
    */ready) printf '{"readyConnections":1}' ;;
esac
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/bin/bash
pid=''
while [ $# -gt 0 ]; do [ "$1" != -p ] || pid="$2"; shift; done
printf 'p%s\nf3\nn127.0.0.1:%s\n' "$pid" $((20000 + pid % 1000))
EOF
cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/bash
case "$*" in "-x bitcoind" | "-x bitviewd" | "-x bitview_mcp") exit 0 ;; esac
exec /usr/bin/pgrep "$@"
EOF
printf '#!/bin/bash\necho %s\n' "'{\"Self\":{\"DNSName\":\"m4-1.tail.ts.net.\"}}'" > "$TMP/bin/tailscale"
chmod +x "$TMP"/bin/* "$TMP"/server/*.sh
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
script="$TMP/server/tunnels.sh"
pid_file="$HOME/.config/dots/running/tunnels.pid"

tokens() {
    printf '%s\n' "$@" > "$TMP/server/.tokens"
}
# The running tunnels.sh's cloudflared processes, and how many.
tunnels() {
    /usr/bin/pgrep -P "$(cat "$pid_file" 2>/dev/null || echo 0)" -x cloudflared | sort | tr '\n' ' '
}
count() {
    local list
    list="$(tunnels)"
    set -- $list
    echo "$#"
}

tokens "prod tok-prod" "mcp tok-mcp" "m4-1 tok-own"
"$script" > "$TMP/workload.log" 2>&1 &
workload=$!
ON_EXIT='kill "$workload" 2>/dev/null; pkill -f "$TMP/bin/cloudflared" 2>/dev/null'
for _ in $(seq 1 50); do
    [ "$(count)" -ne 3 ] || break
    sleep 0.1
done
check "it starts a tunnel for each token" [ "$(count)" -eq 3 ]
before="$(tunnels)"

tokens "m4-1 tok-own"
check "a reload returns once the tunnels the file dropped have stopped" "$script" reload
check "only the own tunnel is left" [ "$(count)" -eq 1 ]
own="$(tunnels)"
own="${own% }"
check "the own tunnel keeps its process" contains "$before" "$own"
check "the tokens it runs on are recorded" \
    [ "$(cat "$HOME/.config/dots/running/tunnels")" = "$(shasum "$TMP/server/.tokens" | cut -d ' ' -f 1)" ]

tokens "prod tok-prod" "mcp tok-mcp" "m4-1 tok-own"
check "a reload with --wait returns once every tunnel is connected" "$script" reload --wait
check "the shared tunnels are back" [ "$(count)" -eq 3 ]
tokens "prod tok-prod" "m4-1 tok-own"
check "and once those the file dropped have stopped" "$script" reload --wait
check "so mcp has left by then" [ "$(count)" -eq 2 ]
tokens "prod tok-prod" "mcp tok-mcp" "m4-1 tok-own"
check "they take mcp back" "$script" reload --wait
check "and the own tunnel still keeps its process" contains "$(tunnels)" "$own"

mv "$pid_file" "$TMP/pid"
"$script" reload >/dev/null 2>&1
mv "$TMP/pid" "$pid_file"
check "a tunnels.sh without reloads is restarted instead" grep -qx "stop tunnels" "$TMP/workloads.calls"

kill -TERM "$workload"
wait "$workload" 2>/dev/null
sleep 0.3
check "stopped, it stops its tunnels" [ -z "$(/usr/bin/pgrep -f "$TMP/bin/cloudflared")" ]
check "and removes its pid file" [ ! -e "$pid_file" ]
finish
