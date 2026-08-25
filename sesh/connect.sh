#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

selected="$(
  sesh list --icons | fzf-tmux -p 80%,70% \
    --no-sort --tac --ansi --border-label ' sesh ' --prompt '⚡  ' \
    --header '  ^a all ^t tmux ^g configs ^x zoxide ^d tmux kill ^f find ^c scratch' \
    --bind 'tab:down,btab:up' \
    --bind 'ctrl-a:change-prompt(⚡  )+reload(sesh list --icons)' \
    --bind 'ctrl-t:change-prompt(🪟  )+reload(sesh list -t --icons)' \
    --bind 'ctrl-g:change-prompt(⚙️  )+reload(sesh list -c --icons)' \
    --bind 'ctrl-x:change-prompt(📁  )+reload(sesh list -z --icons)' \
    --bind 'ctrl-f:change-prompt(🔎  )+reload(fd -H -d 2 -t d -E .Trash . ~)' \
    --bind 'ctrl-c:become($HOME/.dotfiles/sesh/create_scratch.sh)' \
    --bind 'ctrl-d:execute(tmux kill-session -t {2..})+change-prompt(⚡  )+reload(sesh list --icons)' \
    --preview-window 'right:55%' \
    --preview 'sesh preview {}'
)"
[ -z "$selected" ] && exit 0

sesh connect "$selected"

# Label the current window with the sesh item name instead of the program name.
# Strip ANSI colour codes, take the trailing token (name or path), then the basename.
name=$(printf '%s\n' "$selected" | perl -pe 's/\e\[[0-9;]*m//g' | awk '{print $NF}')
tmux rename-window -- "${name##*/}"
