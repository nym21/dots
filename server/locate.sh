#!/usr/bin/env bash
set -euo pipefail

current_output() {
    SwitchAudioSource -c -t output -f json | plutil -extract uid raw -
}

select_output() {
    SwitchAudioSource -t output -u "$1" >/dev/null &&
        [ "$(current_output)" = "$1" ]
}

original_output=""
playback_output=""
saved_volume=""
saved_mute=""
AUDIOMXD_HOLD=/var/run/com.local.audiomxd-hold
holding_audiomxd=false

restore_audio() {
    if [ -n "$saved_volume" ] && [ -n "$saved_mute" ]; then
        if [ -z "$playback_output" ] || select_output "$playback_output"; then
            osascript -e "set volume output volume $saved_volume output muted $saved_mute" >/dev/null ||
                echo "Could not restore the speaker's volume and mute state." >&2
        else
            echo "Playback device is unavailable; could not restore its volume." >&2
        fi
    fi
    if [ -n "$original_output" ]; then
        select_output "$original_output" || echo "Could not restore the previous audio output." >&2
    fi
    # The server's login-screen guard suspends audiomxd again once released.
    if [ "$holding_audiomxd" = true ]; then
        sudo -n /bin/rm -f "$AUDIOMXD_HOLD" ||
            echo "Could not release the audiomxd hold; it expires within a minute." >&2
    fi
}

trap restore_audio EXIT
trap 'exit 0' INT TERM HUP

# At the login screen the server's guard keeps audiomxd suspended. Hold it
# running for playback; the guard honors a hold refreshed within a minute.
stopped_audiomxd="$(
    ps -axo state=,comm= |
        awk '$1 ~ /T/ && $2 == "/usr/libexec/audiomxd" { found = 1 } END { if (found) print "yes" }'
)"
if [ "$(stat -f %Su /dev/console)" = root ] || [ -n "$stopped_audiomxd" ]; then
    sudo -v
    echo "Temporarily resuming audiomxd for playback."
    holding_audiomxd=true
    sudo -n /usr/bin/touch "$AUDIOMXD_HOLD"
    sudo -n /usr/bin/killall -CONT audiomxd || true
fi

# Use an existing selector if available; never install anything.
if command -v SwitchAudioSource >/dev/null 2>&1; then
    original_output="$(current_output)"
    playback_output="$original_output"
    # Apple Silicon Macs expose the internal speaker with this device UID.
    if select_output BuiltInSpeakerDevice; then
        playback_output=BuiltInSpeakerDevice
        echo "Using the built-in speaker."
    else
        select_output "$original_output"
        echo "Built-in speaker unavailable; using the current audio output." >&2
    fi
else
    echo "Using the current audio output. Select the built-in speaker in Sound settings if needed."
fi

saved_volume="$(osascript -e 'output volume of (get volume settings)')"
saved_mute="$(osascript -e 'output muted of (get volume settings)')"
osascript -e 'set volume output volume 100 output muted false'

echo "Playing a short sound repeatedly on $(hostname) at 100% volume. Press Ctrl-C to stop."
while true; do
    # Refresh the hold; this also keeps sudo authorized for cleanup.
    if [ "$holding_audiomxd" = true ]; then
        sudo -n /usr/bin/touch "$AUDIOMXD_HOLD"
    fi
    afplay /System/Library/Sounds/Ping.aiff
    sleep 1
done
