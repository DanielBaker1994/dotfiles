#!/usr/bin/env bash
# fzf-free workspace switcher: native Tk popup, themed like sketchybar.
# Wrapper: if a switcher process is already running, deliver a toggle event by
# touching a flag file it polls; otherwise start one in the background.
# Also records the currently focused window at keypress time (before the
# switcher takes focus) so the switcher can hand focus back when dismissed.
SCRIPT="$HOME/.dotfiles/aerospace/workspace_switcher.py"
FLAG="/tmp/workspace-switcher-toggle"
FOCUS_FILE="/tmp/workspace-switcher-focus"

PID=$(pgrep -f "workspace_switcher.py" | head -1)

# Signal the switcher FIRST so a slow/hanging `aerospace list-windows --focused`
# (which happens when no window is focused) never blocks the toggle.
if [ -n "$PID" ]; then
    touch "$FLAG"
else
    nohup "$SCRIPT" >/dev/null 2>&1 &
fi

# Capture the focused window in the background so the toggle is always instant.
(
    LINE=$(aerospace list-windows --focused --format '%{window-id} %{app-pid}')
    WID=${LINE%% *}
    APID=${LINE##* }
    if [ -n "$WID" ] && { [ -z "$PID" ] || [ "$APID" != "$PID" ]; }; then
        echo "$WID $APID" > "$FOCUS_FILE"
    fi
) &
disown