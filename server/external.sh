# Sourced by the workload launchers. Exits unless the external volume is
# mounted, so nothing writes to the boot disk under /Volumes before it is, as
# when a LaunchDaemon starts first at boot.

EXTERNAL_VOLUME="/Volumes/External"

if [ ! -d "$EXTERNAL_VOLUME" ] || ! mount | awk -v mountpoint="$EXTERNAL_VOLUME" \
    '$2 == "on" && $3 == mountpoint { found = 1 } END { exit !found }'; then
    echo "External volume is not mounted at $EXTERNAL_VOLUME." >&2
    exit 1
fi
