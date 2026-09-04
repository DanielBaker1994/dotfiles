#!/usr/bin/env bash
# Fuzzy-search all AeroSpace workspaces and switch to the selected one.
# Invoked globally via:  alt-enter = exec-and-forget ghostty -e <this>
# Enter switches, ESC cancels. The trailing sleep keeps the terminal alive a
# moment after switching so AeroSpace doesn't yank focus back (#1097/#1371).
aerospace list-workspaces --all |
    fzf --prompt='workspace> ' \
        --header='enter: switch | esc: cancel' \
        | xargs -r aerospace workspace
sleep 1