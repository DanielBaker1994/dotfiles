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

# Save the focused window unless it's the switcher itself (a hide-toggle).
LINE=$(aerospace list-windows --focused --format '%{window-id} %{app-pid}')
WID=${LINE%% *}
APID=${LINE##* }
if [ -n "$WID" ] && { [ -z "$PID" ] || [ "$APID" != "$PID" ]; }; then
    echo "$WID" > "$FOCUS_FILE"
fi

if [ -n "$PID" ]; then
    touch "$FLAG"
else
    nohup "$SCRIPT" >/dev/null 2>&1 &
fi