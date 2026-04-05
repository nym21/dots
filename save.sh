#!/usr/bin/env bash
set -e

DOTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$DOTS_DIR/home"

echo "Saving dotfiles..."
mkdir -p "$HOME_DIR/.config/"{fish,ghostty,zed,zellij}

# Config files
cp ~/.config/fish/config.fish "$HOME_DIR/.config/fish/"
cp ~/.config/starship.toml "$HOME_DIR/.config/"
cp ~/.config/ghostty/config "$HOME_DIR/.config/ghostty/"
cp ~/.config/zed/settings.json "$HOME_DIR/.config/zed/"
cp ~/.config/zellij/config.kdl "$HOME_DIR/.config/zellij/"

# Zed: add auto_install_extensions from installed extensions
ZED_EXT_DIR=~/Library/Application\ Support/Zed/extensions/installed
if [ -d "$ZED_EXT_DIR" ]; then
    EXT_JSON="  \"auto_install_extensions\": {\n"
    first=true
    for ext in "$ZED_EXT_DIR"/*/; do
        [ "$first" = true ] && first=false || EXT_JSON+=",\n"
        EXT_JSON+="    \"$(basename "$ext")\": true"
    done
    EXT_JSON+="\n  },"
    sed -i '' "s/^{$/{\n$EXT_JSON/" "$HOME_DIR/.config/zed/settings.json"
fi

find "$HOME_DIR" -name ".DS_Store" -delete

# Packages
echo "Exporting packages..."
cargo install --list 2>/dev/null | grep -E "^[a-z]" | grep -v "(http" | cut -d' ' -f1 > "$DOTS_DIR/cargo.txt"

echo "Done!"
