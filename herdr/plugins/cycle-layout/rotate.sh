#!/usr/bin/env bash
# tmux rotate-window (prefix+Space): every pane moves one slot back in reading
# order (top-left first) and the first pane wraps to the last slot, so N presses
# bring each of N panes into the top/main slot once. Uses `pane swap`, which
# keeps the layout and split sizes; only the panes trade places.
# Pass "prev" to rotate the other way.
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
command -v "$herdr" >/dev/null 2>&1 || herdr=herdr
dir="${1:-next}"
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || { echo "rotate.sh: no HERDR_PANE_ID" >&2; exit 1; }

layout=$("$herdr" pane layout --pane "$pane")
exec python3 -I - "$herdr" "$dir" "$layout" <<'PY'
import json, subprocess, sys
herdr, direction, raw = sys.argv[1:4]
lay = json.loads(raw)["result"]["layout"]
ids = [p["pane_id"] for p in sorted(lay["panes"], key=lambda p: (p["rect"]["y"], p["rect"]["x"]))]
if len(ids) < 2:
    sys.exit(0)
# Bubble one pane along the slots: swapping it with each next slot in turn
# carries it to the far end while everyone else shifts one slot toward it.
#   next: slot 0's pane goes to the end, slot 1's pane becomes slot 0
#   prev: the last pane comes to slot 0
order = ids if direction == "next" else ids[::-1]
mover = order[0]
for other in order[1:]:
    subprocess.run([herdr, "pane", "swap", "--source-pane", mover, "--target-pane", other],
                   check=True, capture_output=True)
PY
