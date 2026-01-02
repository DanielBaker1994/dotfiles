#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

trap 'echo "Error: Failed to create/remove directory or file. Exiting."; exit 1' ERR

main() {

    BACKUP_ROOT="/tmp/backup_configs_$(date +%Y%m%d_%H%M%S)"

    mkdir -p "$BACKUP_ROOT" || {
        echo "Error: Failed to create backup directory. Exiting."
        exit 1
    }
    declare -A dotfiles

    dotfiles["$HOME/.bash_profile"]="$SCRIPT_DIR/bash/.bash_profile"
    dotfiles["$HOME/.bashrc"]="$SCRIPT_DIR/bash/.bashrc"
    dotfiles["$HOME/.inputrc"]="$SCRIPT_DIR/bash/.inputrc"
    dotfiles["$HOME/.config/kitty"]="$SCRIPT_DIR/kitty"
    dotfiles["$HOME/.config/nvim"]="$SCRIPT_DIR/nvim"
    dotfiles["$HOME/.tmux.conf"]="$SCRIPT_DIR/tmux/.tmux.conf"
    dotfiles["$HOME/.config/starship.toml"]="$SCRIPT_DIR/starship/starship.toml"

    for home_path in "${!dotfiles[@]}"; do
        source_path="${dotfiles[$home_path]}"
        if [[ -L $home_path ]]; then
            unlink "$home_path"
            echo "Removed symbollic link at $home_path"
        else
            echo "Failed to unlink $home_path. Exit before removing files"
            exit 1
        fi

        if [[ -f $home_path ]]; then
            echo "$home_path file found, backing it up."
            cp "$home_path" "$BACKUP_ROOT" || {
                echo "Error: Failed to backup file $home_path. Exiting."
                exit 1
            }
        elif [[ -d $home_path ]]; then
            echo "$home_path directory found, backing it up."
            cp -r "$home_path" "$BACKUP_ROOT" || {
                echo "Error: Failed to backup directory $home_path. Exiting."
                exit 1
            }
        else
            continue
        fi
    done

    for home_path in "${!dotfiles[@]}"; do
        source_path="${dotfiles[$home_path]}"
        if [[ -f $home_path || -L $home_path ]]; then
            rm "$home_path" || {
                echo "Error: Failed to remove file $home_path. Exiting."
                exit 1
            }
        elif [[ -d $home_path ]]; then
            rm -r "$home_path" || {
                echo "Error: Failed to remove directory $home_path. Exiting."
                exit 1
            }
        fi
        if ln -s "$source_path" "$home_path"; then
            echo "Created symlink: $source_path -> $home_path"
        else
            echo "Failed to create symlink: $source_path -> $home_path"
        fi

    done

}

main
