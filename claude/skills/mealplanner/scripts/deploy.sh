#!/usr/bin/env bash
# Deploy what's on GitHub main to the mealplanner container (CT102).
# Needs an open ssh master (bash ~/.claude/skills/proxmox-ssh/scripts/connect.sh mealplanner).
# Never touches product-photos-reseed.service or its docker containers (the API poller).
set -euo pipefail
ssh -o BatchMode=yes mealplanner 'set -euo pipefail
cd /opt/kitchen
dirty=$(git status --porcelain --untracked-files=no)
if [ -n "$dirty" ]; then echo "Server checkout has uncommitted changes, refusing to deploy:"; echo "$dirty"; exit 1; fi
before=$(git rev-parse --short HEAD)
git pull -q --ff-only origin main
after=$(git rev-parse --short HEAD)
echo "server: $before -> $after"
# the venv holds a NON-editable copy of tools/, so every change needs a reinstall
.venv/bin/pip install -q --no-deps /opt/kitchen/tools
systemctl restart mealplanner.service
sleep 3
systemctl is-active mealplanner.service product-photos-reseed.service | paste -sd" " | sed "s/^/mealplanner, reseed: /"
curl -fsS http://127.0.0.1:8765/app/api/session; echo'
