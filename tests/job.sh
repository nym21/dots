#!/usr/bin/env bash
# server/job.sh: one job at a time, its status, and one from an earlier boot.
source "$(dirname "$0")/lib.sh"
export HOME="$TMP"
job="$REPO/server/job.sh"
logs="$HOME/Library/Logs/dots"

"$job" start 'sleep 1; exit 7'
check "a job starts" [ -e "$logs/fleet.pid" ]
check "and has no status while it runs" [ -z "$("$job" status)" ]
check "a second waits for it, status 3" status_is 3 "$job" start true
sleep 1.5
check "its status once it ended" [ "$("$job" status)" = 7 ]
check "its output in the log" [ -e "$logs/fleet.log" ]

# Read in a tight loop as they end, so a read lands between its checks.
gone=0
for _ in $(seq 1 30); do
    "$job" start 'sleep 0.1' 2> /dev/null || continue
    while :; do
        status="$("$job" status)"
        [ -z "$status" ] || break
    done
    [ "$status" != gone ] || gone=$((gone + 1))
done
check "a job read as it ends is never taken for gone" [ "$gone" -eq 0 ]

rm -f "$logs/fleet.status"
echo "$$ 1000000" > "$logs/fleet.pid"
check "one from an earlier boot is gone, though a process took its number" [ "$("$job" status)" = gone ]
check "and does not hold the next" "$job" start true
until [ -e "$logs/fleet.status" ]; do
    sleep 0.05
done

rm -f "$logs/fleet.status"
echo "$$" > "$logs/fleet.pid"
check "a pid file of the old form counts as gone" [ "$("$job" status)" = gone ]
finish
