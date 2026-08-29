#!/usr/bin/env bash

#https://github.com/Maxteabag/sqlit - pipx install sqlit-tui - /Users/danielbaker/.local/bin/sqlit-tui - ~/.local/bin/sqlit --mock=sqlite-demo
#gr to execute is nice
# ~/.config/sqlit/

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

BACKUP_ROOT="/tmp/backup_configs_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_ROOT"

declare -A dotfiles=(
    ["$HOME/.bash_profile"]="$SCRIPT_DIR/bash/.bash_profile"
    ["$HOME/.bashrc"]="$SCRIPT_DIR/bash/.bashrc"
    ["$HOME/.inputrc"]="$SCRIPT_DIR/bash/.inputrc"
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
