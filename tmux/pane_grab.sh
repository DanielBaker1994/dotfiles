#!/usr/bin/env bash
# pane_grab.sh — fuzzy-find any pane across all tmux sessions and pull it
# into the window this script was invoked from.
#
# Bound to prefix+j in .tmux.conf:
#   bind-key -T prefix 'j' run-shell "$HOME/.dotfiles/tmux/pane_grab.sh"
#
# Behaviour:
#   - lists every pane as  session:window.pane  window_name  [running command]
#   - live preview shows the pane's visible contents
#   - pane already in the current window  -> just focus it
#   - pane anywhere else                  -> join-pane it into the current
#     window (its old window is destroyed if that was its only pane)
set -euo pipefail

if [[ -z "${TMUX:-}" ]]; then
    echo "pane_grab: not running inside tmux" >&2
    exit 1
fi
if ! command -v fzf-tmux >/dev/null 2>&1; then
    echo "pane_grab: fzf-tmux not found on PATH" >&2
    exit 1
fi

cur_pane=$(tmux display-message -p '#{pane_id}')
cur_window=$(tmux display-message -p '#{window_id}')

fmt='#{pane_id}|#{session_name}:#{window_index}.#{pane_index}  #{window_name}  [#{pane_current_command}]'

sel=$(tmux list-panes -a -F "$fmt" |
    awk -F'|' -v self="$cur_pane" '$1 != self' |
    fzf-tmux -p 80%,60% \
        --prompt='grab pane > ' \
        --header='enter: pull pane into current window | esc: cancel' \
        --delimiter='|' --with-nth=2.. \
        --preview='tmux capture-pane -p -t {1}' \
        --preview-window='right:55%') || true

[[ -n "$sel" ]] || exit 0

pane_id=${sel%%|*}

if [[ "$(tmux display-message -p -t "$pane_id" '#{window_id}')" == "$cur_window" ]]; then
    tmux select-pane -t "$pane_id"
else
    tmux join-pane -s "$pane_id" -t "$cur_window"
    tmux select-pane -t "$pane_id"
fi
