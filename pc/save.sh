#!/usr/bin/env bash
set -e

PC_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(dirname "$PC_DIR")/shared"

# Imported dotfiles are symlinks; edit the files in shared/home/ directly.
echo "Exporting Cargo packages..."
packages="$(cargo install --list)"
# The tools both roles use stay in shared/cargo.txt; the rest is this Mac's.
# Server workloads install their own crates; keep them out of both lists.
printf '%s\n' "$packages" | awk '
    /^[[:alnum:]_-]+ v[^ ]+:$/ && $1 !~ /^(bitviewd|bitviewd_bench|bitview_mcp)$/ { print $1 }
' | grep -vxF -f "$SHARED_DIR/cargo.txt" > "$PC_DIR/cargo.txt" || true

# Rex keeps its settings in its preferences, which it rewrites, so save them
# for pc/setup.sh to write back. Only plain values are kept; the data and
# dictionaries hold its state, such as the last focused session.
if defaults read com.superlogical.rex >/dev/null 2>&1; then
    echo "Exporting Rex settings..."
    {
        echo "# Rex app settings, KEY TYPE VALUE: saved by pc/save.sh, written by pc/setup.sh."
        defaults export com.superlogical.rex - | plutil -convert xml1 -o - - |
            grep -oE '<key>Workspace\.[A-Za-z0-9.]+</key>' | sed -E 's#</?key>##g' | sort -u |
            while read -r key; do
                value="$(defaults read com.superlogical.rex "$key")"
                case "$(defaults read-type com.superlogical.rex "$key")" in
                    *boolean) type=bool; [ "$value" = 1 ] && value=true || value=false ;;
                    *integer) type=int ;;
                    *float) type=float ;;
                    *string) type=string ;;
                    *) continue ;;
                esac
                echo "$key $type $value"
            done
    } > "$PC_DIR/rex-settings"
fi

# The macOS settings dots keeps, those set on this Mac among the ones listed
# here, for pc/setup.sh to write back. Add a DOMAIN KEY line to keep another.
echo "Exporting macOS settings..."
{
    echo "# macOS settings, DOMAIN KEY TYPE VALUE: saved by pc/save.sh, written by pc/setup.sh."
    while read -r domain key; do
        value="$(defaults read "$domain" "$key" 2>/dev/null)" || continue
        case "$(defaults read-type "$domain" "$key")" in
            *boolean) type=bool; [ "$value" = 1 ] && value=true || value=false ;;
            *integer) type=int ;;
            *float) type=float ;;
            *string) type=string; value="${value/#$HOME/~}" ;;
            *) continue ;;
        esac
        echo "$domain $key $type $value"
    done <<'KEYS'
NSGlobalDomain AppleShowAllExtensions
NSGlobalDomain AppleInterfaceStyle
NSGlobalDomain AppleInterfaceStyleSwitchesAutomatically
NSGlobalDomain AppleAccentColor
NSGlobalDomain AppleHighlightColor
NSGlobalDomain AppleShowScrollBars
NSGlobalDomain AppleKeyboardUIMode
NSGlobalDomain ApplePressAndHoldEnabled
NSGlobalDomain KeyRepeat
NSGlobalDomain InitialKeyRepeat
NSGlobalDomain com.apple.swipescrolldirection
NSGlobalDomain com.apple.trackpad.scaling
NSGlobalDomain _HIHideMenuBar
NSGlobalDomain NSAutomaticSpellingCorrectionEnabled
NSGlobalDomain NSAutomaticCapitalizationEnabled
NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled
NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled
NSGlobalDomain NSAutomaticDashSubstitutionEnabled
NSGlobalDomain NSAutomaticInlinePredictionEnabled
com.apple.dock autohide
com.apple.dock autohide-delay
com.apple.dock tilesize
com.apple.dock orientation
com.apple.dock magnification
com.apple.dock largesize
com.apple.dock show-recents
com.apple.dock mru-spaces
com.apple.dock minimize-to-application
com.apple.dock show-process-indicators
com.apple.dock wvous-tl-corner
com.apple.dock wvous-tr-corner
com.apple.dock wvous-bl-corner
com.apple.dock wvous-br-corner
com.apple.finder AppleShowAllFiles
com.apple.finder ShowPathbar
com.apple.finder ShowStatusBar
com.apple.finder FXPreferredViewStyle
com.apple.finder FXDefaultSearchScope
com.apple.finder NewWindowTarget
com.apple.finder _FXShowPosixPathInTitle
com.apple.finder _FXSortFoldersFirst
com.apple.finder ShowHardDrivesOnDesktop
com.apple.finder ShowExternalHardDrivesOnDesktop
com.apple.finder ShowRemovableMediaOnDesktop
com.apple.finder ShowMountedServersOnDesktop
com.apple.screencapture location
com.apple.screencapture type
com.apple.screencapture disable-shadow
com.apple.screencapture show-thumbnail
com.apple.AppleMultitouchTrackpad Clicking
com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag
com.apple.AppleMultitouchTrackpad TrackpadRightClick
com.apple.desktopservices DSDontWriteNetworkStores
com.apple.desktopservices DSDontWriteUSBStores
com.apple.WindowManager GloballyEnabled
com.apple.WindowManager EnableStandardClickToShowDesktop
com.apple.WindowManager EnableTiledWindowMargins
com.apple.menuextra.clock ShowSeconds
KEYS
} > "$PC_DIR/macos-settings"

echo "Done!"
