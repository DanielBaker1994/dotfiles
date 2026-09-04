#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Dotfiles deployment for this Mac.
# Symlinks every managed config into place, installs font/tooling deps, and
# applies the macOS system tweaks the setup depends on.
#
# NOTE: the window-manager + status-bar stack (aerospace, sketchybar, borders,
# karabiner, workspace switcher) moved out to the standalone app repo:
#   ~/workspace-switcher/setup.sh   (one command, does its own install)
#
# Safe to re-run: existing symlinks are replaced, real files are backed up to
# /tmp/backup_configs_<timestamp>. Does not uninstall anything.
#
# Requires: brew, sudo (for the ghostty bin symlink).
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

# Icon fonts
#   font-sketchybar-app-font -> app-icon glyphs for the bar (used by
#       ~/workspace-switcher/config/sketchybar/sketchybar-app-font/dist/icon_map.json)
#   font-hack-nerd-font      -> terminal/tmux
brew install --cask font-sketchybar-app-font
brew install --cask font-hack-nerd-font

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

echo
echo "Done. Backups (if any) are in: $BACKUP_ROOT"