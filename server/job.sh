#!/usr/bin/env bash
set -euo pipefail

# The job fleet runs on this server, one at a time, which finishes here
# whatever happens to the workstation or the connection, as when it sleeps:
# its output in ~/Library/Logs/dots/fleet.log, its status beside it once it
# ends, and meanwhile its process in fleet.pid, with the boot it runs in, so a
# process of a later boot that took its number is never taken for it.
#
#   job.sh start COMMAND   run COMMAND, a shell command, as the job; status 3
#                          while an earlier one still runs
#   job.sh status          the job's status once it ended, gone if it ended
#                          without one, as in a restart, nothing while it runs

LOGS="$HOME/Library/Logs/dots"

# This boot, as macOS names it: exact, where the boot time follows the clock.
booted() {
    sysctl -n kern.bootsessionuuid
}

# Whether the job's process runs, in this boot.
running() {
    local pid boot
    { read -r pid boot < "$LOGS/fleet.pid"; } 2>/dev/null || return 1
    [ "$boot" = "$(booted)" ] && kill -0 "$pid" 2>/dev/null
}

case "$#:${1:-}" in
    2:start)
        mkdir -p "$LOGS"
        if [ ! -e "$LOGS/fleet.status" ] && running; then
            echo "An earlier job of fleet's still runs here." >&2
            exit 3
        fi
        rm -f "$LOGS/fleet.status"
        # A subshell keeps an exit in COMMAND from skipping the status, which is
        # written whole, so it is never read half written.
        nohup bash -c "( $2 ); echo \$? > '$LOGS/fleet.status.new' && mv '$LOGS/fleet.status.new' '$LOGS/fleet.status'" \
            </dev/null >"$LOGS/fleet.log" 2>&1 &
        echo "$! $(booted)" > "$LOGS/fleet.pid"
        ;;
    1:status)
        # The status, else the process, else the status again: a job that ends
        # between the two has written its status by then, so is never gone.
        if [ -e "$LOGS/fleet.status" ]; then
            cat "$LOGS/fleet.status"
        elif running; then
            :
        elif [ -e "$LOGS/fleet.status" ]; then
            cat "$LOGS/fleet.status"
        else
            echo gone
        fi
        ;;
    *)
        echo "Usage: $0 start COMMAND | status" >&2
        exit 1
        ;;
esac
