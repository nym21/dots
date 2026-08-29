#!/usr/bin/env bash
set -e

SESSION="main"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux"
STATE_FILE="$STATE_DIR/$SESSION.tsv"

if tmux has-session -t "=$SESSION" 2>/dev/null || [ ! -s "$STATE_FILE" ]; then
    exit 0
fi

decode() {
    printf '%s' "$1" | base64 -D
}

created_session=false
active_window=""
current_window_index=""
current_window_active=0
current_window_zoomed=0
current_window_name=""
current_window_layout=""
current_window_started=false
current_active_pane=""

cleanup() {
    local restore_exit_code=$?
    trap - EXIT
    if [ "$restore_exit_code" -ne 0 ] && [ "$created_session" = true ]; then
        tmux kill-session -t "=$SESSION" 2>/dev/null || true
    fi
    exit "$restore_exit_code"
}
trap cleanup EXIT

finish_window() {
    if [ "$current_window_started" != true ]; then
        return
    fi

    tmux select-layout -t "$SESSION:$current_window_index" "$current_window_layout" >/dev/null
    tmux rename-window -t "$SESSION:$current_window_index" "$current_window_name"

    if [ -n "$current_active_pane" ]; then
        tmux select-pane -t "$SESSION:$current_window_index.$current_active_pane"
    fi
    if [ "$current_window_zoomed" -eq 1 ]; then
        tmux resize-pane -Z -t "$SESSION:$current_window_index.$current_active_pane"
    fi
    if [ "$current_window_active" -eq 1 ]; then
        active_window="$current_window_index"
    fi
}

while IFS=$'\t' read -r kind field1 field2 field3 field4 field5; do
    case "$kind" in
        version)
            if [ "$field1" != 1 ]; then
                echo "Unsupported tmux layout version: $field1" >&2
                exit 1
            fi
            ;;
        window)
            finish_window
            current_window_index="$field1"
            current_window_active="$field2"
            current_window_zoomed="$field3"
            current_window_name="$(decode "$field4")"
            current_window_layout="$field5"
            current_window_started=false
            current_active_pane=""
            ;;
        pane)
            if [ -z "$current_window_index" ]; then
                echo "Invalid tmux layout: pane without window." >&2
                exit 1
            fi

            pane_active="$field1"
            pane_path="$(decode "$field2")"
            [ -d "$pane_path" ] || pane_path="$HOME"

            if [ "$current_window_started" = false ]; then
                if [ "$created_session" = false ]; then
                    created_target="$(tmux new-session \
                        -d \
                        -P \
                        -F '#{window_index}:#{pane_index}' \
                        -s "$SESSION" \
                        -n "$current_window_name" \
                        -c "$pane_path")"
                    created_session=true

                    initial_window_index="${created_target%%:*}"
                    created_pane="${created_target#*:}"
                    if [ "$initial_window_index" != "$current_window_index" ]; then
                        tmux move-window \
                            -s "$SESSION:$initial_window_index" \
                            -t "$SESSION:$current_window_index"
                    fi
                else
                    created_pane="$(tmux new-window \
                        -d \
                        -P \
                        -F '#{pane_index}' \
                        -t "$SESSION:$current_window_index" \
                        -n "$current_window_name" \
                        -c "$pane_path")"
                fi

                current_window_started=true
            else
                created_pane="$(tmux split-window \
                    -d \
                    -P \
                    -F '#{pane_index}' \
                    -t "$SESSION:$current_window_index" \
                    -c "$pane_path")"
            fi

            if [ "$pane_active" -eq 1 ]; then
                current_active_pane="$created_pane"
            fi
            ;;
    esac
done < "$STATE_FILE"

finish_window

if [ "$created_session" = false ]; then
    echo "Invalid or empty tmux layout: $STATE_FILE" >&2
    exit 1
fi

if [ -n "$active_window" ]; then
    tmux select-window -t "$SESSION:$active_window"
fi

trap - EXIT
