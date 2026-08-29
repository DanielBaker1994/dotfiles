#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

current_dir="$(tmux display-message -p -t . '#{pane_current_path}' 2>/dev/null || printf '%s' "$HOME")"

selected="$(
    sesh list -c -t -d --icons | fzf-tmux -p 90%,85% \
        --no-sort --ansi --border-label ' sesh ' --prompt '⚡  ' \
        --header '  ^a ⚡ all ^t 🪟 tmux ^g ⚙️ configs ^x 📁 zoxide
  ^b 🌐 browser ^c 📝 scratch ^f 🔎 find ^d 🗑️ kill' \
        --bind 'tab:down,btab:up' \
        --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
        --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
        --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
        --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
        --bind "ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash -E .git -E node_modules . '$current_dir')" \
        --bind 'ctrl-c:become($HOME/.dotfiles/sesh/create_scratch.sh)' \
        --bind 'ctrl-b:become($HOME/.dotfiles/sesh/create_browser.sh)' \
        --bind 'ctrl-d:execute(tmux kill-session -t {2..})+reload(sesh list -c -t -d --icons)' \
        --preview-window 'right:60%' \
        --preview 'sesh preview {}'
)" || selected=""
[ -z "$selected" ] && exit 0

sesh connect "$selected"

name=$(printf '%s\n' "$selected" | perl -pe 's/\e\[[0-9;]*m//g' | awk '{print $NF}')
tmux rename-window -- "${name##*/}"
