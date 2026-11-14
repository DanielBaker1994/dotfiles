---
name: mealplanner
description: Work on the user's Home Kitchen / MealPlannerApp (github.com/DanielBaker1994/MealPlannerApp), which runs on the mealplanner container (CT102). Covers the local clone, committing straight to main, deploying to the server, restarting it safely without touching the product-photo API poller, and iPhone 13 mini UI testing of the web app with Playwright. Use whenever the user mentions the meal planner, Home Kitchen, the kitchen app, its web app at /app/, or `ssh mealplanner`.
---

# MealPlannerApp (Home Kitchen)

This dotfiles repo is PUBLIC: never write the tailnet name, access codes or keys in here.
Get the hostname at runtime: `ssh -o BatchMode=yes mealplanner tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'`
The web app is `https://<that name>/app/` (tailnet only, via `tailscale serve` -> 127.0.0.1:8765).

## Connect
Use the **proxmox-ssh** skill: `bash ~/.claude/skills/proxmox-ssh/scripts/connect.sh --work mealplanner` (5 h idle timeout, the user's choice)
(YubiKey PIN + tap), then `ssh -o BatchMode=yes mealplanner '...'`.

## How the user wants changes made (agreed 2026-11-14)
- **Make changes locally** in `~/code/MealPlannerApp`, so the user can track them. Don't edit code on the server.
- **Commit and push straight to `main`.** No PRs, no branches: the user doesn't review them.
- Then deploy with `bash ~/.claude/skills/mealplanner/scripts/deploy.sh`. It refuses if the server checkout is
  dirty, does `git pull --ff-only`, reinstalls, restarts and prints the status.
- Always tell the user what you changed and whether it was local or on the server.
- Commit author: the same identity as the repo's existing commits (`git log -1 --format='%an <%ae>'`), set as
  repo-local git config in the clone (the global git name is a placeholder). `gh` is logged in on the Mac (HTTPS).

## Server layout (CT102)
| What | Where |
|---|---|
| Checkout (root-owned git clone of main) | `/opt/kitchen` |
| App service | `mealplanner.service`: runs `/opt/kitchen/.venv/bin/kitchen serve` as user `kitchen`, port 8765 |
| Python package | **non-editable** install of `/opt/kitchen/tools` in `/opt/kitchen/.venv`: every code or static change needs `.venv/bin/pip install --no-deps /opt/kitchen/tools` + a restart (deploy.sh does it) |
| Web frontend | `tools/src/kitchen_tools/web/static/` (vanilla ES modules, `app.css`). Served `Cache-Control: no-cache`, no service worker |
| Secrets | `/opt/kitchen/.env` -> rendered to `tools/config/secrets.json` on every start |
| Data | `/opt/kitchen/build` (server data, logs) |

**Restarting `mealplanner.service` is fine. NEVER stop or restart `product-photos-reseed.service`** or its docker
containers (`kitchen-pp-*`, `gluetun`): that's the user's long-running product-photo API poller. Also leave
`/root/env-gluetun` alone.

**Access code: switched off on 2026-11-14** (user's call: `KITCHEN_ACCESS_CODE=` blank; backup with the old one at
`/root/env.bak-pre-blank-code-20261114`). With it blank, the API needs no login, so headless browsers can test the app directly.
The user doesn't want it back unless they ask.

## Tests
Run locally: `cd ~/code/MealPlannerApp && python3 -m venv .venv && .venv/bin/pip install -e "tools[dev]" && cd tools && ../.venv/bin/python -m pytest -q`.
Known failures that are NOT regressions (2026-11-14): `test_seed_loader::test_deeply_nested_file_is_unusable_not_a_crash`
(fails on Python 3.14, the server runs 3.13) and `test_web::test_store_writes_get_a_newer_time_each_time`
(two writes in the same millisecond get the same timestamp on a fast Mac).
Running pytest on the server as `kitchen` fails with permission errors on `shared-data/schemas` (environment, not code).

## iPhone UI testing (in Docker, never npx on the Mac)
The user's phone is an **iPhone 13 mini** (Safari). **Run browser tests only in the container**: the user doesn't want
npm/npx code running on the Mac (supply-chain risk, 2026-11-14). `ui-test/` holds it all:
- `Dockerfile`: Microsoft's `playwright:v1.57.0-noble` image pinned by digest (browsers built in) + the `playwright`
  library from the committed `package-lock.json`, `npm ci --ignore-scripts`. Bump version + digest + lockfile together
  (regenerate the lockfile *inside* the image: `npm install --package-lock-only --ignore-scripts`).
- `run.sh <script.js> <out-dir> [args]`: builds the image once, finds the app's host from the Mac's Tailscale
  (no ssh needed), runs as the user's uid with `--cap-drop ALL --read-only`, mounting only the scripts (ro) and `<out-dir>`.
  `<out-dir>` must be under `$HOME` (colima only shares the home folder): use `~/Library/Caches/mealplanner-ui-test/...`.
  `ENGINE=webkit` (or `chromium`) runs one engine. Needs `colima start`.
- `iphone-check.js [route ...]`: emulates "iPhone 13 Mini" (375x629, DPR 3, touch) in **WebKit** (closest to real Safari)
  and Chromium. Per route: full-page + `-screen.png` (first screen), horizontal overflow, HTTP >= 400 by URL, page errors.
  Routes: `#/meals #/history #/recipes #/recipe/<id> #/edit/<id> #/cook/<id> #/library #/shopping #/pantry #/settings
  #/diagnostics #/products` (a recipe id: `curl -s https://<host>/app/api/meals/home`).
- `popup-check.js`: regression check for the Products pop-up (PASS/FAIL per engine).
Read the screenshots (shrink first: `sips -Z 900 in.png --out out.png`). For new interactions copy popup-check.js:
`page.getByRole(...).tap()`, and `page.addStyleTag` to try a CSS fix live before editing the code.

Emulation artifacts, not bugs: the tab bar looks see-through (headless WebKit doesn't draw `backdrop-filter`), number
inputs show spinners (iOS doesn't). Don't wait for `networkidle`: lazy images in hidden lists stay pending in WebKit
forever; wait for `load` plus an element.

Lessons:
- Layout breakpoints are 600 / 760 / 900px. Bugs that show "on iPhone but not in the browser" are usually the <=760px rules.
- Avoid percentage heights / `minmax(0, N%)` grid rows inside scroll containers or `<dialog>`s: they collapse on phones.
  Give the box an explicit height (`min(45dvh, 340px)` with a `vh` fallback) and pin images with `position:absolute; inset:0; object-fit:contain`.
- Files the server reads must be readable by user `kitchen`. Anything run as root on the server can leave root-only files
  (mkstemp = 0600): after any root run, `find /opt/kitchen/ios/HomeKitchen/Resources /opt/kitchen/build -type f -user root ! -perm -o=r`.
- Fixed: ad720fb Products "On my lists" pop-up (picture vanished, facts clipped); 4ba65aa every recipe photo 500
  (seed images root-only 0600 after a root pipeline run).
  16e5bfd store products' aisle (`KitchenRules.product_canonical_and_aisle`: a produce word only counts when it ends the
  name); a99a637 selects styled (`appearance:none` + chevron), pantry placeholder shortened.
- Items already on a list keep their stored aisle. There's no "set aisle" API: to move one, DELETE `shopping/items/<id>`
  and POST `shopping/items` with `{"product": {code, listText, name, image}}` (goes through the synced code path).
- Test aisle-rule changes against the real catalogue first (read-only, on the server as `kitchen`): products.sqlite
  `select name from products order by id limit 20000`, compare old vs new aisle, read samples of each move.
