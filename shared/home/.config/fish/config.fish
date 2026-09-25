fish_add_path /opt/homebrew/bin ~/.cargo/bin ~/.local/bin

if status is-interactive
    starship init fish | source
end
