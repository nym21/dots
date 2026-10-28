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

rm -f "$logs/fleet.status"
echo "$$ 1000000" > "$logs/fleet.pid"
check "one from an earlier boot is gone, though a process took its number" [ "$("$job" status)" = gone ]
check "and does not hold the next" "$job" start true

rm -f "$logs/fleet.status"
echo "$$" > "$logs/fleet.pid"
check "a pid file of the old form counts as gone" [ "$("$job" status)" = gone ]
finish
