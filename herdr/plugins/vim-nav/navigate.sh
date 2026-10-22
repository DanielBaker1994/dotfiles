#!/usr/bin/env bash
#
# vim-nav — herdr side of seamless Ctrl+h/j/k/l navigation.
#
# Invoked by a herdr keybind as: navigate.sh <left|down|up|right>
# (bindings live in ~/.dotfiles/herdr/config.toml)
#
# vim-tmux-navigator for herdr: if the focused pane's FOREGROUND process is
# Vim/Neovim, the chord is handed back into that pane so Vim moves between its
# own splits (and, at a split edge, calls `herdr pane focus` itself — see the
# pane_nav function in ~/.dotfiles/nvim/init.lua). Any other foreground process
# (shell, agent TUI, tests...) just moves herdr's pane focus directly — the same
# split of labor as tmux/.tmux.conf's is_vim bindings.
#
# Adapted from paulbkim-dev/vim-herdr-navigation (MIT License).
#
# HERDR_NAV_PASSTHROUGH_RE: optional regex (matched against the lower-cased
# process name) that lets other TUIs owning Ctrl+hjkl themselves — lazygit,
# k9s, vi-sql... — receive the chord instead of losing it to pane focus. Off by
# default. Unlike Vim they don't cross out at their own edge: leave the pane
# with prefix+h/j/k/l.

set -euo pipefail
# handler timing -> herdr/herdr-prof.sh (no-op if missing)
# shellcheck source=../prof.sh
source "$HOME/.dotfiles/herdr/plugins/prof.sh" 2>/dev/null || true

dir="${1:?usage: navigate.sh <left|down|up|right>}"
herdr="${HERDR_BIN_PATH:-herdr}"
# `herdr update` replaces the binary under a still-running server, leaving
# HERDR_BIN_PATH pointing at a deleted inode — every exec would fail 127.
if ! [ -x "$herdr" ]; then
    herdr="$(command -v herdr || true)"
fi
if [ -z "$herdr" ]; then
    echo "navigate.sh: no usable herdr binary (stale HERDR_BIN_PATH and none on PATH)" >&2
    exit 127
fi
pane="${HERDR_PANE_ID:-}"

case "$dir" in
    left)  key="ctrl+h" ;;
    down)  key="ctrl+j" ;;
    up)    key="ctrl+k" ;;
    right) key="ctrl+l" ;;
    *) echo "navigate.sh: unknown direction: $dir" >&2; exit 2 ;;
esac

# Foreground process names that mean "Vim is in control of this pane". Same
# matcher vim-tmux-navigator uses: vi, vim, nvim, view, gvim, *diff, ...
vim_re='^g?(view|l?n?vim?x?)(diff)?$'
passthrough_re="${HERDR_NAV_PASSTHROUGH_RE:-}"

forward=0
if [ -n "$pane" ] && command -v jq >/dev/null 2>&1; then
    # jq is optional: without it every key still moves pane focus, just without
    # Vim awareness (only the in-Vim split movement is lost).
    if "$herdr" pane process-info --pane "$pane" 2>/dev/null \
        | jq -e --arg vim "$vim_re" --arg pass "$passthrough_re" \
            '.result.process_info.foreground_processes[]?.name
             | ascii_downcase
             | select(test($vim) or ($pass != "" and (try test($pass) catch false)))' >/dev/null 2>&1; then
        forward=1
    fi
fi

if [ "$forward" -eq 1 ]; then
    exec "$herdr" pane send-keys "$pane" "$key"
elif [ -n "$pane" ]; then
    exec "$herdr" pane focus --direction "$dir" --pane "$pane"
else
    # No pane env (shouldn't happen from a keybind): fall back to global focus.
    exec "$herdr" pane focus --direction "$dir" --current
fi
