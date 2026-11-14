#!/usr/bin/env bash
# Run a UI test script from this folder in the container, against the live mealplanner web app.
#   bash run.sh <script.js> <out-dir> [args...]      e.g. bash run.sh iphone-check.js /tmp/shots '#/products'
# The script gets the app's base URL as its first argument and writes screenshots to /out (= <out-dir>).
# Needs Docker (colima start). Builds the image once (tag mealplanner-uitest:1.57.0).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=$1; out=$2; shift 2
mkdir -p "$out"
# the Mac's own Tailscale knows the name: no ssh / YubiKey needed. Override with MEALPLANNER_HOST=...
ts=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
host=${MEALPLANNER_HOST:-$("$ts" status --json | python3 -c 'import json,sys;print(next(p["DNSName"].rstrip(".") for p in json.load(sys.stdin)["Peer"].values() if p["DNSName"].startswith("mealplanner.")))')}
ip=$(dscacheutil -q host -a name "$host" | awk '/ip_address/{print $2; exit}')
docker image inspect mealplanner-uitest:1.57.0 >/dev/null 2>&1 || docker build -q -t mealplanner-uitest:1.57.0 "$here" >/dev/null
# no host network, no capabilities, read-only root; only the scripts (ro) and the output folder are mounted
exec docker run --rm --init --ipc=host --cap-drop ALL --security-opt no-new-privileges --read-only \
  --tmpfs /tmp --tmpfs /home/pwuser --add-host "$host:$ip" \
  -v "$here:/t/scripts:ro" -v "$(cd "$out" && pwd):/out" --user "$(id -u):$(id -g)" -e HOME=/tmp -e ENGINE="${ENGINE:-}" \
  mealplanner-uitest:1.57.0 node "/t/scripts/$script" "https://$host/app/" /out "$@"
