#!/usr/bin/env bash
# Cycle the focused tab through: columns -> rows -> main-left (tmux next-layout).
# herdr has no layout API, so panes are re-attached with `pane move`.
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
command -v "$herdr" >/dev/null 2>&1 || herdr=herdr
dir="${1:-next}"
pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || { echo "cycle.sh: no HERDR_PANE_ID" >&2; exit 1; }

layout=$("$herdr" pane layout --pane "$pane")
exec python3 -I - "$herdr" "$pane" "$dir" "$layout" <<'PY'
import json, subprocess, sys
herdr, cur, direction, raw = sys.argv[1:5]
lay = json.loads(raw)["result"]["layout"]
tab = lay["tab_id"]
panes = sorted(lay["panes"], key=lambda p: (p["rect"]["y"], p["rect"]["x"]))
ids = [p["pane_id"] for p in panes]
n = len(ids)
if n < 2:
    sys.exit(0)

dirs = {s["direction"] for s in lay["splits"]}
# current shape: all "right" = columns, all "down" = rows, else main-left/other
if dirs == {"right"}: state = 0
elif dirs == {"down"}: state = 1
else: state = 2
step = 1 if direction == "next" else -1
target = (state + step) % 3

def run(*args):
    r = subprocess.run([herdr, *args], check=True, capture_output=True, text=True)
    return json.loads(r.stdout)["result"]

def move(p, tgt, d, ratio):
    run("pane", "move", p, "--tab", tab, "--target-pane", tgt, "--split", d,
        "--ratio", f"{ratio:.4f}", "--no-focus")

def chain(members, d, anchor):
    # ratio = share kept by the existing (target) side
    last = anchor
    for i, p in enumerate(members):
        remaining = len(members) - i
        move(p, last, d, 1.0 / (remaining + 1))
        last = p

# `pane move` inside one tab is a no-op, so park everything but the first pane
# in a temporary tab (it closes itself once emptied), then re-attach.
rest = ids[1:]
tmp = None
for p in rest:
    if tmp is None:
        tmp = run("pane", "move", p, "--new-tab", "--no-focus", "--label", "layout-tmp")["move_result"]["pane"]["tab_id"]
    else:
        run("pane", "move", p, "--tab", tmp, "--split", "right", "--no-focus")

if target == 0:   chain(rest, "right", ids[0])
elif target == 1: chain(rest, "down", ids[0])
else:
    move(rest[0], ids[0], "right", 0.5)
    chain(rest[1:], "down", rest[0])
PY
