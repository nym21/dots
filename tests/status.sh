#!/usr/bin/env bash
# server/status.sh --check: its exits, run on the counts it computes, set here.
# shellcheck disable=SC2016,SC2034 # the counts status.sh's check reads, set in its eval
source "$(dirname "$0")/lib.sh"
block="$(sed -n '/^if \[ "\$check" -eq 1 \]; then/,/^fi$/p' "$REPO/server/status.sh")"
CRASH_LOG=/dev/null

# The exit of the check with the counts given as NAME=VALUE....
exits() {
    (
        down=''
        eval "$*"
        check=1
        eval "$block"
        exit 99
    )
    echo $?
}
up='workloads=4 expected=4 names="prod mcp m4-1" ready=3 tunnels=3'

check "serving at the tip: 0" [ "$(exits "$up behind=0")" = 0 ]
check "every tunnel connected, 12 blocks behind: 3" [ "$(exits "$up behind=12")" = 3 ]
check "Bitview not answering: 1" [ "$(exits "$up behind=''")" = 1 ]
check "a tunnel not connected: 1" [ "$(exits 'workloads=4 expected=4 names="prod mcp m4-1" ready=2 tunnels=3 behind=12')" = 1 ]
check "a workload down: 1" [ "$(exits 'workloads=3 expected=4 names="prod mcp m4-1" ready=3 tunnels=3 behind=0 down=" mcp"')" = 1 ]
finish
