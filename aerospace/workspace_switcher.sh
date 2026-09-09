#!/usr/bin/env bash
# fzf-free workspace switcher: native AppKit popup (Swift), themed like
# sketchybar. If the daemon is running (Unix-socket ping succeeds), send a
# toggle message; otherwise build-if-stale and launch it in the background.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/workspace-switcher"
SRC="$DIR/workspace_switcher.swift"
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

# Build if the binary is missing or the source is newer.
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    swiftc -O -swift-version 5 "$SRC" -o "$BIN" >/dev/null 2>&1 || swiftc "$SRC" -o "$BIN"
fi

# Toggle the daemon if it's running; otherwise launch it and toggle once
# (retrying briefly until the socket is up).
if ! "$BIN" toggle >/dev/null 2>&1; then
    nohup "$BIN" >/dev/null 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.05
        "$BIN" toggle >/dev/null 2>&1 && break
    done
fi