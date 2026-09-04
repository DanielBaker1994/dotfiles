# jira-api.sh — Jira Cloud REST API query tool

All jira tooling lives in one place: `~/.config/workspace-switcher/jira/` (scripts +
aliases, sourced from `.bashrc`), data in `~/.cache/workspace-switcher/jira_json/`
(what the jira window reads), cache in `~/.cache/jira/`, config in
`~/.config/jira/config`.

- `jira-api.sh` — query tool + `--sync` cache/drip-feed
- `jira-poll.sh` — polling orchestrator (wraps jira-api, publishes window JSON)
- `jira-seed.sh` — fake-data generator for testing
- `jira-sync-test.sh` — end-to-end sync test
- `jira-doctor.sh` — one-command health check of the whole stack (`--fix` repairs)

Lightweight bash CLI for querying Jira Cloud and keeping a local cache of issues.
Dependencies: `bash` (4.2+), `curl`, `jq`. All verified against the live API
(`/rest/api/3/search/jql` pagination, `/rest/api/2` discovery endpoints).

```
jira-api.sh [OPTIONS] [ISSUE-KEY]
```

With no arguments, starts the interactive wizard.

---

## Setup

### 1. Create a free Jira site (if you don't have one)

- Sign up at https://www.atlassian.com/software/jira/free with your Atlassian
  account. The free plan ships with sample projects (e.g. `SAM1`, `KAN`) full of
  realistic issues, assignees, versions and sprints.
- The API token page (https://id.atlassian.com) is only where you *mint* tokens —
  it has no data. One token works for **all** Atlassian Cloud sites (Jira, Confluence, …).

### 2. Get an API token

https://id.atlassian.com → Security → API tokens. This is your "Confluence token" —
it's a single token for the whole Atlassian Cloud account.

Verify it immediately (uses the same `JIRA_TOKEN_API` pattern as every command below):

```bash
SITE="$(grep JIRA_SITE  ~/.config/jira/config | cut -d\' -f2)"
EMAIL="$(grep JIRA_EMAIL ~/.config/jira/config | cut -d\' -f2)"
JIRA_TOKEN_API="$(grep JIRA_TOKEN ~/.config/jira/config | cut -d\' -f2)"

curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/myself" | jq .displayName
# → "Atlassin Lover" (or whatever your display name is)
```

(If you haven't run `jira-api --init` yet, paste the token from the API-token page
into `~/.config/jira/config` first, then run the lines above.)

### 3. Configure

```bash
jira-api --init
```

Writes `~/.config/jira/config` (chmod 600):

```ini
JIRA_SITE='https://your-site.atlassian.net'
JIRA_EMAIL='you@example.com'
JIRA_TOKEN='ATATT3x...'
JIRA_DEFAULT_PROJECT='SAM1'
JIRA_MAX='25'
```

Precedence: `--site/--email/--token` flags > environment variables > config file.
Config can be overridden with `--config FILE`.

### 4. Credentials for copy-paste (no secret in this doc)

Every curl below uses these three lines — they pull your real credentials from
the config at runtime, so the commands work as-is:

```bash
SITE="$(grep JIRA_SITE  ~/.config/jira/config | cut -d\' -f2)"
EMAIL="$(grep JIRA_EMAIL ~/.config/jira/config | cut -d\' -f2)"
JIRA_TOKEN_API="$(grep JIRA_TOKEN ~/.config/jira/config | cut -d\' -f2)"
```

### 5. Login / auth — the commands

Jira Cloud has no "log in and get a bearer token" endpoint for personal scripts —
**basic auth with your API token *is* the login**. Two equivalent spellings:

```bash
# simplest: curl's -u flag (email:token)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/myself" | jq .displayName

# explicit Authorization header (same thing, built by hand):
AUTH="$(printf '%s:%s' "$EMAIL" "$JIRA_TOKEN_API" | base64)"
curl -s -H "Authorization: Basic $AUTH" "$SITE/rest/api/2/myself" | jq .displayName
```

There is also a real OAuth bearer-token flow (`POST https://auth.atlassian.com/oauth/token`),
but it requires registering an app (client id + secret) — not worth it for
personal scripts. Basic auth + API token is the supported, simple path.

### Pre-flight checks (run on every invocation)

1. `curl` and `jq` must be installed (dies with a brew hint otherwise)
2. `JIRA_SITE`, `JIRA_EMAIL`, `JIRA_TOKEN` must be set (names the missing ones)
3. Login is verified via `GET /rest/api/2/myself` — prints `login OK (<name>)`,
   aborts with exit 1 on any auth failure before anything else runs
   (`--no-auth-check` skips it)

---

## CLI options

### Discovery / setup

| Option | Description |
|---|---|
| `--init` | Interactively write `~/.config/jira/config` |
| `--myself` | Print the authenticated user (`/rest/api/2/myself`) |
| `--config FILE` | Use `FILE` instead of `~/.config/jira/config` |
| `--site URL`, `--email X`, `--token T` | One-off overrides (not stored) |

### Filters (combined with `AND` into JQL)

| Option | JQL produced |
|---|---|
| `-p, --project KEY` | `project = "KEY"` |
| `-a, --assignee NAME` | `assignee = "NAME"` — `NAME~` means fuzzy (`assignee ~`) |
| `-r, --release NAME` | `fixVersion = "NAME"` (release == fix version) |
| `-s, --status NAME` | `status = "NAME"` |
| `-u, --reporter NAME` | `reporter = "NAME"` |
| `-t, --text TERM` | `text ~ "TERM"` |
| `-d, --date EXPR` | `FIELD[:OP]VALUE`, e.g. `updated:-7d`, `due:>2024-05-01`, `created:startOfMonth()`; FIELD defaults to `updated`; values starting with `-` become `>=` |
| `-j, --jql RAW` | Raw JQL, overrides all filters |

Example:

```bash
jira-api -p SAM1 -a mike.cho -r 11.1 -s Blocked -d updated:-30d -R
# project = "SAM1" AND assignee = "mike.cho" AND fixVersion = "11.1" AND status = "Blocked" AND updated >= -30d ORDER BY updated DESC
```

### Ordering / limits

| Option | Description |
|---|---|
| `-R, --recent` | `ORDER BY updated DESC` (recently updated first) |
| `-S, --sort EXPR` | `ORDER BY EXPR`, e.g. `priority`, `created ASC` |
| `-n, --max N` | Max results (default 25; the search API caps pages at 100) |

### Output

| Option | Description |
|---|---|
| `-o table` (default) | Column-aligned table: KEY, STATUS, ASSIGNEE, RELEASE, UPDATED, TITLE |
| `-o json` | JSON array of the cleaned shape (see below) |
| `--debug` | Print the JQL and the request URL |
| `--no-auth-check` | Skip the `/myself` login verification |

JSON shape (matches the issue you asked for, plus date):

```json
{
  "key": "JT-1001",
  "title": "Agent every development say quality",
  "status": "Blocked",
  "assignee": "mike.cho",
  "release": "11.1",
  "description": "Opportunity all behavior discussion. ..."
}
```

### `-verbose` (debug dumping)

Appends to two files (each run separated by a `--- <timestamp> ---` header):

- `/tmp/jira_api_dump.txt` — all raw curl endpoints the script uses, with
  copy-paste-ready `curl -u 'email:token' ...` examples (7 endpoints: search,
  single issue, projects, assignable users, versions, statuses, myself)
- `/tmp/jira_api_trace.txt` — full bash `set -x` trace with
  `PS4='+${EPOCHREALTIME} ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}(): '`
  (float epoch time + file:line:function per line), written via `BASH_XTRACEFD`
  so your terminal stderr stays clean

### Interactive mode

`jira-api -i` (or just `jira-api` with no args). Walks through:

`Project → Assignee → Release (fixVersion) → Status → Recent days → Sort → Max results`

- Options are fetched live from the API (projects, assignable users, versions, statuses)
- **Enter** = the `[default]` shown in the prompt; **0** = any; type a **number** or a **name**
- Typed project keys are validated against the live project list and re-prompted
  on a typo instead of failing with 404s

---

## `--sync WINDOW` — local cache + drip feed

Loads issues changed within a window into a local cache and merges by key.
**No polling, no scheduling** — trigger it however you like (cron, launchd,
keypress); you decide the window each run, so a missed poll window is simply
covered by using a longer window next time.

```
jira-api --sync 30m         # updated in the last 30 minutes
jira-api --sync 2h          # last 2 hours
jira-api --sync 7d          # last 7 days
jira-api --sync 1w          # last week
jira-api --sync 2026-09-10  # since that date
jira-api --sync "2026-09-12 10:00"   # datetime (site local time)
jira-api --sync full        # everything (initial load)
```

### Cache layout

```
~/.cache/jira/jiras.json                 # object keyed by issue key
~/.cache/jira/state                      # LAST_SYNC, WINDOW, UPDATED, TOTAL
~/.cache/jira/dumps/YYYY_MM_DD.json      # pretty-printed snapshots, one per run
~/.cache/jira/dumps/YYYY_MM_DD_1.json    # …_2, _3 … for re-runs the same day
```

- **Cache entry shape**: `key, title, status, assignee, release, description,
  updated, reporter, project, comments` — comments are `[{author, body, created,
  updated}]`
- Merge is a **keyed upsert**: changed issues overwrite their key, everything
  else is untouched, one atomic rewrite (tmp + mv) per sync — **no history kept**
- Snapshots are written on **every** sync run, nicely formatted with `jq`,
  first run of the day `YYYY_MM_DD.json`, re-runs numbered `_1, _2, …`
- Summary on stderr: `sync 30m: fetched 2, changed 2, cache now 13` +
  `snapshot: ~/.cache/jira/dumps/2026_09_12_3.json`

### How the sync works

1. Window → JQL: relative windows use Jira's own relative dates
   (`updated >= -30m` — timezone-safe); date-only windows use
   `updated >= "2026-09-10"`; datetimes are interpreted in the **site's** local
   timezone (Jira's JQL quirk — it ignores the `Z` suffix)
2. Full sync JQL: `project != null` (the new search API rejects unbounded
   queries; `id >= 0` no longer works)
3. Paged loop: `GET /rest/api/3/search/jql?jql=...&fields=...&maxResults=100`,
   following `nextPageToken` until `isLast: true` (v3 has **no `total` field**)
4. Per changed issue: `GET /rest/api/2/issue/{key}?fields=comment` for comments
   (comment activity bumps the issue's `updated`, so the window catches it)

### Polling — `jira-poll.sh` (the orchestrator)

`jira-poll.sh` wraps `jira-api.sh`: it syncs the cache and then publishes the
JSON files the jira window reads. **It never polls itself** — launchd calls it
every 10 minutes; each run decides its own window.

**Window from the last run time (no hardcoded interval):**

1. The state file (`~/.cache/jira/poll-state`) records `LAST_POLL` (local time)
   after every run
2. The next run computes its window as `LAST_POLL − JIRA_POLL_MARGIN`
   (default 5 min — covers Jira's search-index lag)
3. A missed poll window (laptop asleep, machine off) is therefore covered
   automatically: the window stretches back to whenever the poll last
   succeeded — no data gap, no manual `--window`
4. First run / no cache → full sync

**Outputs** (atomic tmp+mv, into `~/.cache/workspace-switcher/jira_json/`):

- `all.json` — the generic "all jiras" category (every cached issue, sorted by
  `updated` DESC)
- `<PROJECT>.json` — specialized per-project files when `JIRA_POLL_PROJECTS`
  (config) or `--projects` is set; `--projects all` = one file per project
  found in the cache. Each file becomes its own **tab** in the jira window

**Config keys** (in `~/.config/jira/config`, written by `jira-api --init`):

| Key | Default | Meaning |
|---|---|---|
| `JIRA_POLL_MARGIN` | `5` | minutes subtracted from `LAST_POLL` for the window |
| `JIRA_POLL_STATE` | `~/.cache/jira/poll-state` | poll state file |
| `JIRA_POLL_OUT_DIR` | `~/.cache/workspace-switcher/jira_json` | window JSON output dir |
| `JIRA_POLL_PROJECTS` | (empty) | comma list → specialized per-project files |

**Launching at start (macOS — launchd, not cron):**

```bash
cp ~/.config/workspace-switcher/jira/com.jira.poll.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jira.poll.plist
# verify it ran: launchctl list | grep jira.poll   and   cat ~/.cache/jira/poll-state
```

The plist runs `jira-poll.sh --quiet` every 600s (`StartInterval`), plus once at
load (`RunAtLoad`). launchd survives sleep/wake and retries the interval on its
own; cron does not wake a sleeping Mac.

**Manual runs:**

```bash
jira-poll.sh                # poll since last run, publish all.json
jira-poll.sh --init         # force full sync (reset)
jira-poll.sh --window 2h    # explicit window override
jira-poll.sh --projects SAM1,KAN   # also publish SAM1.json + KAN.json
jira-poll.sh --projects all # per-project files for every project in the cache
jira-poll.sh --dry-run      # transform only, write nothing
```

Exit codes: 0 = success, 1 = API failure after 3 retries (10s/30s/60s backoff),
2 = usage/config error.

### Health check — `jira-doctor.sh` (the "is everything registered?" command)

One command asserts the whole stack, printing PASS/FAIL/WARN per check plus
**when the poll last ran and when it runs next**:

```bash
jira-doctor            # read-only report; exit 1 if anything fails
jira-doctor --fix      # also: install/load the launchd agent, rebuild a stale
                       # workspace-switcher binary, refresh a drifted plist
```

Checks, in order:

| Group | What it asserts |
|---|---|
| dependencies | `curl`, `jq`, `aerospace`, `swiftc` on PATH |
| config | `~/.config/jira/config` exists with `JIRA_SITE`/`JIRA_EMAIL`/`JIRA_TOKEN` |
| jira api | live `GET /rest/api/2/myself` login (prints the display name) |
| cache & json | `~/.cache/jira/jiras.json` issue count; `aerospace/jira_json/all.json` mtime |
| poll agent | plist installed at `~/Library/LaunchAgents/com.jira.poll.plist` (matches the repo copy) and **loaded** in launchd |
| poll schedule | `LAST_POLL`/`STATUS`/`ITEMS` from `~/.cache/jira/poll-state`, then `next run = LAST_POLL + StartInterval` (overdue ⇒ WARN if loaded, FAIL if not) |
| switcher daemon | binary newer than its Swift sources, daemon process alive, `commands.conf` has `copy-fields`, `aerospace.toml` floats `app-name = workspace-switcher` and wires `focus-bridge.sh` into `on-focus-changed`, karabiner Hyper+S/J/N bindings present |

Alias: `jira-doctor` (see the jira aliases in `bash/.bashrc`, sourced from `.bashrc`).

### The jeera window (jira list popup)

The window that renders `jira_json/*.json` is the `workspace-switcher`
daemon's list window (`aerospace/commands.conf` `[jira]` section). Beyond
search/filter/tabs it supports copying issues:

- every row has a **checkbox**; clicking it (or `Ctrl+Space` on the selected row)
  ticks the row for copying
- the header shows **`copy all`** (nothing ticked) or **`copy N`**; clicking it
  writes one TSV line per picked row to the clipboard —
  `key<TAB>title<TAB>status<TAB>assignee<TAB>release`
- each row also carries two tiny actions next to the checkbox:
  **`open in browser`** (`$JIRA_SITE/browse/<KEY>`) and **`more details`**
  (a minimal read-only floating window rendering that one jira with every
  field unwrapped; Esc dismisses, re-invoking refreshes the same window)
- the fields and the on/off switch are config-driven, so any future list
  window gets the same UI for free:

```ini
copy-fields = key,title,status,assignee,release   # empty/absent = no copy UI
copy-format = tsv
```

The window stays popped up while AeroSpace moves focus between other apps
(`sticky`), and AeroSpace's own focus keys reach it: `aerospace/focus-bridge.sh`
(an `on-focus-changed` hook) records the focused window id and the daemon
activates itself, since macOS refuses to activate an accessory app from
another process. Event-driven — no polling, no extra load on AeroSpace or
sketchybar. jeera's glyph is the official Jira mark shipped as
`aerospace/jira_icon.png` (picker rows, menu bar, window header); the window
watches its json sources and reloads a tab within ~2s of the poll rewriting
it, so an open window never shows stale rows.

Every window behavior is commands.conf-driven (no code per window):
`checkbox`, `resize`, `drag`, `sticky`, `height`, `search-width`,
`row-actions` (`browser`, `details`), `browse-url`, `max-row-stretch`, `font`,
plus the copy keys above. Header buttons are live: `copy selected` /
`copy N`, `copy config path`, and `copy <active-tab> path` refresh on every
tab change and reload; the `Last File Write:` line sits left, after the item
count.

### `/doctor` (palette command) and its poll buttons

`commands.conf` sections with `type = output` run a shell command and show its
output in a read-only floating window (Hyper+S → `/doctor`; re-invoking re-runs
into the same window, Esc dismisses, header click copies the output).

The doctor window's header grows one **`poll <target>` button per json the poll
publishes** (`poll all`, `poll KAN`, `poll SAM1`, … — derived from
`aerospace/jira_json/` at open time and refreshed after every run). Clicking one
runs `jira-poll.sh --window 30m --projects <target>` and streams that poll's
output into the same window; the open jeera window picks the rewritten json up
on its own within ~2s. The 30m window avoids the sliding-`LAST_POLL` race (a
lagged change can fall outside a window computed from the previous poll).

### Why the drip-feed design works (verified on a live sandbox)

The `updated` field is a single "last touched" timestamp that bumps on:

- any field edit (status, assignee, summary, priority, labels, versions, sprint, …)
- comments — added, edited, deleted
- worklogs — added/edited/deleted
- attachments — added/removed
- issue links — both sides

It does **not** bump on votes, watchers, or permission changes.

Verified empirically on `sudosignup.atlassian.net`: create issue → comment →
worklog → attachment → status transition all moved `updated`, and
`updated >= -1m` caught the issue.

### Known gaps / gotchas

- **Deletions are invisible** to any `updated` query — deleted issues simply stop
  appearing. Handle with a periodic `--sync full` reconcile if you care
- **Overlap race**: an issue edited *while* syncing can be missed; de-dupe by
  key and/or use a slightly longer window than your poll interval
- **No `total`** in the v3 API — paginate with `nextPageToken`/`isLast`
- **Datetimes in site-local time** — `--sync "2026-09-12 10:00"` means 10:00 in
  the site's timezone, not UTC
- Old `/rest/api/2/search` was removed in 2026 (CHANGE-2046) — always use
  `/rest/api/3/search/jql` for searches; the v2 issue/project/status discovery
  endpoints still work and return plain-text descriptions

### End-to-end sync test (`~/.config/workspace-switcher/testbackups/jira-sync-test.sh`)

One command that proves the cache pipeline works, using fake data:

```bash
jira-sync-test
```

It runs this exact sequence (each step prints `== step N ==`):

1. **Populate the cache** — `jira-api --sync 30m`
2. **Dump the cached items as JSON** — writes `baseline.json` (pretty-printed
   with jq, keyed by Jira issue number e.g. `SAM1-170`) and a sorted baseline
   key list (`jq -r 'keys[]' ~/.cache/jira/jiras.json`)
3. **Seed 100 fake issues** — `jira-seed -n 100 --versions --min-desc long --comments`
   (recorded in `~/.cache/jira/seed_keys.txt`; the 100 new keys = diff of that
   file before vs after)
4. **Mutate existing issues** — 5 random baseline issues get a comment
   (marker text `sync-test comment on <KEY>`), 5 random baseline issues get
   their assignee toggled (assigned → unassigned or vice versa), so the sync
   is exercised against real edits, not just new issues
5. **Poll the last 5 minutes** — `jira-api --sync 5m` (the drip-feed call).
   Jira's search index lags up to a few minutes behind writes, so the test
   re-polls every 30s (max 4 tries) until the mutated issues show up in the
   cache — the same overlap tolerance a real drip-feed needs
6. **Assert** — the cache now contains:
   - every baseline issue (nothing lost), and
   - all 100 newly seeded issues (everything caught), and
   - total == baseline + 100, and
   - a fresh dated snapshot in `~/.cache/jira/dumps/`
7. **Assert comment changes** — each mutated issue's cache entry contains its
   marker comment
8. **Assert assignee changes** — each toggled issue's cache entry matches the
   expected assignee (or unassigned)

Cleanup when done with the test data: `jira-seed --cleanup` (deletes only the
seeded keys, never your real issues).

---

## Raw curl commands (copy-paste)

All 7 endpoints the script uses, with real copy-pasteable commands.
Run the three `SITE`/`EMAIL`/`JIRA_TOKEN_API` lines from
[Setup §4](#credentials-for-copy-paste-no-secret-in-this-doc) first, then any block below:

```bash
# 1. Search issues (JQL) — used by every query; pages with nextPageToken
curl -s -u "$EMAIL:$JIRA_TOKEN_API" \
  "$SITE/rest/api/3/search/jql?jql=project%20%3D%20SAM1&fields=summary,status,assignee,fixVersions,description,updated&maxResults=25" \
  | jq -r '.issues[] | "\(.key)\t\(.fields.status.name)\t\(.fields.summary)"'

# 2. Single issue (plain-text description)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/issue/SAM1-1" | jq .

# 3. List projects
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/project" | jq -r '.[] | "\(.key)\t\(.name)"'

# 4. Assignable users for a project (assignee suggestions)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" \
  "$SITE/rest/api/2/user/assignable/search?project=SAM1&maxResults=50" \
  | jq -r '.[].displayName'

# 5. Versions / releases for a project (fixVersion values)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/project/SAM1/versions" | jq -r '.[].name'

# 6. All statuses
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/status" | jq -r 'unique_by(.name)[].name'

# 7. Login check (who am I?)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/myself" | jq '.displayName'
```

Useful extras beyond the script's own calls:

```bash
# Paginate - follow nextPageToken until isLast (v3 has no "total", and
# returns bare {id} objects unless you pass fields=...)
TOK=""
while :; do
  QS="jql=project%20%3D%20SAM1&fields=key&maxResults=5"
  [[ -n "$TOK" ]] && QS="$QS&nextPageToken=$TOK"
  PAGE="$(curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/3/search/jql?$QS")"
  printf '%s' "$PAGE" | jq -r '.issues[].key'
  TOK="$(printf '%s' "$PAGE" | jq -r '.nextPageToken // ""')"
  [[ "$(printf '%s' "$PAGE" | jq -r '.isLast')" == "true" ]] && break
done

# Comments on an issue
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/issue/SAM1-1?fields=comment" \
  | jq -r '.fields.comment.comments[] | "\(.author.displayName): \(.body)"'

# Same thing via the script: jira-api -verbose appends all of the above to /tmp/jira_api_dump.txt
```

---

## Quick reference

```bash
# script
jira-api --init                                   # configure once
jira-api                                          # interactive wizard
jira-api -p SAM1 -s Done -R                       # filtered, recently updated
jira-api SAM1-10                                  # single issue
jira-api -p SAM1 -n 3 -o json                     # JSON shape
jira-api --sync full                              # initial cache load
jira-api --sync 30m                               # drip-feed update (your trigger)
jira-api -verbose --sync 30m                      # + dump + trace files
jira-doctor                                       # assert the whole stack (last/next run)
jira-doctor --fix                                 # + install launchd agent / rebuild binary
jq '.["SAM1-1"]' ~/.cache/jira/jiras.json         # read cached issue

# raw curl (run the SITE/EMAIL/TOKEN lines first — see Setup §4)
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/myself" | jq .displayName   # login check
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/2/issue/SAM1-1" | jq .        # one issue
curl -s -u "$EMAIL:$JIRA_TOKEN_API" "$SITE/rest/api/3/search/jql?jql=project%20%3D%20SAM1%20AND%20status%20%3D%20Done&fields=key,summary&maxResults=25" | jq -r '.issues[].key'
```