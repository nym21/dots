fish_add_path ~/.cargo/bin ~/.local/bin
# Sets PATH (bin and sbin), MANPATH, INFOPATH, and HOMEBREW_* ahead of the above.
if test -x /opt/homebrew/bin/brew
    /opt/homebrew/bin/brew shellenv fish | source
end

if status is-interactive
    starship init fish | source
end
