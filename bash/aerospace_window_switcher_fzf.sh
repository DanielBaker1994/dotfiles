#!/usr/bin/env bash
# Fuzzy-search any AeroSpace window (id | app | title) and focus it.
# Invoked globally via:  alt-space = exec-and-forget ghostty -e <this>
# Enter focuses, ESC cancels. The trailing sleep keeps the terminal alive a
# moment after focusing so AeroSpace doesn't yank focus back (#1097/#1371).
aerospace list-windows --all |
    fzf --prompt='window> ' \
        --header='enter: focus | esc: cancel' \
        --bind='enter:execute($SHELL -c "aerospace focus --window-id {1}")+abort'
sleep 1
