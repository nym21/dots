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
}

trap restore_audio EXIT
trap 'exit 0' INT TERM HUP

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
    afplay /System/Library/Sounds/Ping.aiff
    sleep 1
done
