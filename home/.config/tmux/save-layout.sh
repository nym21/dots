#!/usr/bin/env bash
set -e

SESSION="main"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tmux"
STATE_FILE="$STATE_DIR/$SESSION.tsv"

if ! tmux has-session -t "=$SESSION" 2>/dev/null; then
    exit 0
fi

encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

mkdir -p "$STATE_DIR"
tmp="$(mktemp "$STATE_DIR/$SESSION.XXXXXX")"

cleanup() {
    if [ -n "${tmp:-}" ]; then
        rm -f "$tmp"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

printf 'version\t1\n' > "$tmp"

while IFS= read -r window_id; do
    window_index="$(tmux display-message -p -t "$window_id" '#{window_index}')"
    window_active="$(tmux display-message -p -t "$window_id" '#{window_active}')"
    window_zoomed="$(tmux display-message -p -t "$window_id" '#{window_zoomed_flag}')"
    window_name="$(tmux display-message -p -t "$window_id" '#{window_name}')"
    window_layout="$(tmux display-message -p -t "$window_id" '#{window_layout}')"

    printf 'window\t%s\t%s\t%s\t%s\t%s\n' \
        "$window_index" \
        "$window_active" \
        "$window_zoomed" \
        "$(encode "$window_name")" \
        "$window_layout" >> "$tmp"

    while IFS= read -r pane_id; do
        pane_active="$(tmux display-message -p -t "$pane_id" '#{pane_active}')"
        pane_path="$(tmux display-message -p -t "$pane_id" '#{pane_current_path}')"
        [ -n "$pane_path" ] || pane_path="$HOME"

        printf 'pane\t%s\t%s\n' \
            "$pane_active" \
            "$(encode "$pane_path")" >> "$tmp"
    done < <(tmux list-panes -t "$window_id" -F '#{pane_id}')
done < <(tmux list-windows -t "=$SESSION" -F '#{window_id}')

mv "$tmp" "$STATE_FILE"
tmp=""
