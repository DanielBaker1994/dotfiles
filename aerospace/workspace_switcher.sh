#!/usr/bin/env bash
# fzf-free workspace switcher: native AppKit popup (Swift), themed like
# sketchybar. If the daemon is running (Unix-socket ping succeeds), send a
# toggle message; otherwise build-if-stale and launch it in the background.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/workspace-switcher"
MAIN="$DIR/main.swift"
SRC="$DIR/workspace_switcher.swift"
FRAMEWORK="$DIR/PopupWindow.swift"
TMP="${TMPDIR:-/tmp}"
FOCUS_FILE="$TMP/workspace-switcher-focus"

# Record the focused window (wid + app-pid) at keypress time so the switcher
# can hand focus back when dismissed.
LINE=$(aerospace list-windows --focused --format '%{window-id} %{app-pid}')
WID=${LINE%% *}
APID=${LINE##* }
if [ -n "$WID" ]; then
    echo "$WID $APID" > "$FOCUS_FILE"
fi

# Build if the binary is missing or a source file is newer.
if [ ! -x "$BIN" ] || [ "$MAIN" -nt "$BIN" ] || [ "$SRC" -nt "$BIN" ] || [ "$FRAMEWORK" -nt "$BIN" ]; then
    swiftc -O -swift-version 5 "$FRAMEWORK" "$SRC" "$MAIN" -o "$BIN" >/dev/null 2>&1 \
        || swiftc "$FRAMEWORK" "$SRC" "$MAIN" -o "$BIN"
fi

# Toggle the daemon if it's running; otherwise launch it with "show" so the
# popup appears immediately (no retry loop needed).
if ! "$BIN" toggle >/dev/null 2>&1; then
    nohup "$BIN" show >/dev/null 2>&1 &
fi