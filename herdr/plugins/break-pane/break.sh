#!/usr/bin/env bash
# Move the focused pane into a new tab (tmux break-pane).
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
command -v "$herdr" >/dev/null 2>&1 || herdr=herdr
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || { echo "break.sh: no HERDR_PANE_ID" >&2; exit 1; }
exec "$herdr" pane move "$pane" --new-tab
