#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Dotfiles deployment for this Mac.
# Symlinks every managed config into place, installs bar/font/tooling deps,
# and applies the macOS system tweaks the setup depends on.
#
# Safe to re-run: existing symlinks are replaced, real files are backed up to
# /tmp/backup_configs_<timestamp>. Does not uninstall anything.
#
# Requires: brew, sudo (for the ghostty bin symlink).
# See doc/workspace.md -> "AeroSpace + SketchyBar Status Bar" for the full knowledge base + gotchas.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

BACKUP_ROOT="/tmp/backup_configs_$(date +%Y%m%d_%H%M%S)"

# Ghostty CLI on PATH (idempotent; -f ignores "already exists")
sudo ln -sf /Applications/Ghostty.app/Contents/MacOS/ghostty /usr/local/bin/ghostty

mkdir -p "$BACKUP_ROOT"

declare -A dotfiles=(
    # shell
    ["$HOME/.bash_profile"]="$SCRIPT_DIR/bash/.bash_profile"
    ["$HOME/.bashrc"]="$SCRIPT_DIR/bash/.bashrc"
    ["$HOME/.inputrc"]="$SCRIPT_DIR/bash/.inputrc"
    # editors / tools
    ["$HOME/.config/nvim"]="$SCRIPT_DIR/nvim"
    ["$HOME/.tmux.conf"]="$SCRIPT_DIR/tmux/.tmux.conf"
    ["$HOME/.config/starship.toml"]="$SCRIPT_DIR/starship/starship.toml"
    ["$HOME/.config/sesh/sesh.toml"]="$SCRIPT_DIR/sesh/sesh.toml"
    ["$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"]="$SCRIPT_DIR/ghostty/config.ghostty"
    # window manager + status bar
    ["$HOME/.aerospace.toml"]="$SCRIPT_DIR/aerospace/.aerospace.toml"
    ["$HOME/.config/sketchybar"]="$SCRIPT_DIR/sketchybar"
    ["$HOME/.config/borders"]="$SCRIPT_DIR/borders"
)

for home_path in "${!dotfiles[@]}"; do
    source_path="${dotfiles[$home_path]}"

    if [[ ! -e $source_path && ! -L $source_path ]]; then
        echo "Error: source path missing: $source_path" >&2
        exit 1
    fi

    if [[ -L $home_path ]]; then
        rm "$home_path"
    elif [[ -e $home_path ]]; then
        echo "Backing up existing $home_path to $BACKUP_ROOT"
        cp -R "$home_path" "$BACKUP_ROOT/"
        rm -rf "$home_path"
    fi

    mkdir -p "$(dirname "$home_path")"
    ln -s "$source_path" "$home_path"
    echo "Created symlink: $home_path -> $source_path"
done

# ---------------------------------------------------------------------------
# Tooling / dependencies
# ---------------------------------------------------------------------------
echo
echo "==> Ensuring homebrew packages are installed..."

# Status bar + workspace renderer
brew tap felixkratz/formulae
brew install sketchybar
brew install borders                    # JankyBorders — focused-window border

# Icon fonts
#   font-sketchybar-app-font -> app-icon glyphs for the bar
#       (sketchybar-app-font/dist/icon_map.json backs aerospacer.sh lookups)
#   font-hack-nerd-font      -> terminal/tmux
brew install --cask font-sketchybar-app-font
brew install --cask font-hack-nerd-font
brew install pillow                        # workspace_switcher.py (PIL: rounded bg + app icons)

# Workspace rendering: sketchybar/plugins/aerospacer.sh draws one pill per
# workspace and moves the highlight on aerospace_workspace_change.
# The highlight reads $FOCUSED_WORKSPACE from the AeroSpace --trigger payload
# (see .aerospace.toml exec-on-workspace-change).

# ---------------------------------------------------------------------------
# System tweaks (idempotent)
# ---------------------------------------------------------------------------
echo
echo "==> Applying macOS system tweaks..."

# Hide the native menu bar (macOS 26: System Settings > Control Center >
# "Automatically hide and show the menu bar" — this defaults key is equivalent)
defaults write NSGlobalDomain _HIHideMenuBar -bool true && killall Finder

# "Displays have separate Spaces" off (spans-displays = 1): makes every monitor
# share one set of workspaces. AeroSpace recommends this for stable focus and to
# avoid per-display workspace weirdness (e.g. the Raycast launcher shuffle).
# Requires logout/login to take effect.
defaults write com.apple.spaces spans-displays -bool true

# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------
echo
echo "==> Starting services..."
brew services start sketchybar
brew services start borders

echo
echo "Done. Reload bar config anytime with: brew services restart sketchybar"
echo "Backups (if any) are in: $BACKUP_ROOT"