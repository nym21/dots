# shellcheck shell=bash
# Sourced: the password fleet lends a server for one job, in
# ~/.config/dots/password, read here and deleted at once, so it is on disk for
# seconds and then only in this script's memory, never its environment. With
# --stdinpass, from standard input instead, as a script that read it passes it
# on.
lent_password=''
if [ "${1:-}" = --stdinpass ]; then
    IFS= read -r lent_password || true
elif [ -e "$HOME/.config/dots/password" ]; then
    IFS= read -r lent_password < "$HOME/.config/dots/password" || true
    rm -f "$HOME/.config/dots/password"
fi

# Run COMMAND... as root: with the lent password, or else as sudo does, asking
# on the terminal, or failing without one.
as_root() {
    if [ -n "$lent_password" ]; then
        printf '%s\n' "$lent_password" | sudo -S -p '' "$@"
    else
        sudo "$@"
    fi
}

# Pass the lent password on to SCRIPT ARGS..., which sources this with
# --stdinpass, or run it to ask on the terminal.
with_lent() {
    if [ -n "$lent_password" ]; then
        printf '%s\n' "$lent_password" | "$@" --stdinpass
    else
        "$@"
    fi
}
