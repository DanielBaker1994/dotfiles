#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# connect-herdr.sh — sesh-style picker for herdr (prefix+w popup)
#
# The picker UI is herdr-picker.mjs (Node, mouse; drag a split row onto a
# workspace / tab to move it);
# this script is its data / action backend. Without node the fzf picker runs.
#
#   connect-herdr.sh                 picker (node, else fzf)
#   connect-herdr.sh fzf             the fzf picker
#   connect-herdr.sh state           workspaces / tabs / panes as one JSON
#   connect-herdr.sh go LINE|PATH    act on a picked entry (or a scratch path)
#   connect-herdr.sh list [MODE]     entries: all | agents | dirs | browse (| ws | cfg)
#   connect-herdr.sh preview LINE    preview for one entry
#   connect-herdr.sh label LINE      preview border label for one entry
#   connect-herdr.sh help            key / source legend (? in the picker)
#   connect-herdr.sh kill LINE       close a workspace / tab, forget a zoxide dir
#   connect-herdr.sh browser         prompt for a URL, open it in a workspace
#
# Entry line: DISPLAY<TAB>KIND<TAB>TARGET<TAB>SEARCH[<TAB>more]
#   ws  = live herdr workspace (TARGET = workspace id)
#   tab = tab of a live workspace, always listed under it (TARGET = tab id)
#   pane = split of a tab, listed under it (TARGET = pane id; enter focuses the tab)
#   agent = pane running an agent (TARGET = pane id)
#   cfg = sesh.toml session    (TARGET = session name)
#   dir = directory            (TARGET = path)
# SEARCH is what the picker matches on (space label + dir / session name / path).
# more = a non-frecent dir: the picker shows it only while a query is typed.
# fzf can only search fields it shows, so SEARCH is padded far off-screen and
# matched with --nth so it filters the label without showing it.

set -euo pipefail

SESH_TOML="$HOME/.dotfiles/sesh/sesh.toml"
# zoxide dirs in "all": frecency score >= MIN (or a git repo root), top MAX
DIRS_MIN_SCORE="${HERDR_PICK_MIN_SCORE:-1}"
DIRS_MAX="${HERDR_PICK_MAX_DIRS:-12}"
# off-screen pad before the SEARCH field (fzf --no-hscroll keeps it hidden)
SEARCH_PAD="$(printf '%*s' 1000 '')"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

field() { printf '%s' "$1" | cut -d$'\t' -f"$2"; }
expand() {
    local p="$1"
    [[ $p == "~"* ]] && p="$HOME${p:1}"
    printf '%s' "$p"
}

workspaces_json() { herdr workspace list 2>/dev/null || echo '{}'; }

# workspace id for a label, empty if none
workspace_id_for() {
    workspaces_json | jq -r --arg l "$1" \
        'first(.result.workspaces[]? | select(.label == $l) | .workspace_id) // empty'
}

# path / startup_command of a sesh.toml session
sesh_field() {
    python3 - "$SESH_TOML" "$1" "$2" <<'PY'
import sys, tomllib
path, name, field = sys.argv[1:]
with open(path, "rb") as f:
    for s in tomllib.load(f).get("session", []):
        if s.get("name") == name:
            print(s.get(field, ""))
            break
PY
}

current_dir() {
    herdr pane current 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty' || true
}

# workspace/tab/pane lists → one JSON {ws, tabs, panes}
state() {
    jq -n \
        --argjson w "$(herdr workspace list 2>/dev/null || echo '{}')" \
        --argjson t "$(herdr tab list 2>/dev/null || echo '{}')" \
        --argjson p "$(herdr pane list 2>/dev/null || echo '{}')" \
        '{ws: ($w.result.workspaces // []), tabs: ($t.result.tabs // []),
          panes: ($p.result.panes // [])}'
}

# jq helpers shared by list_ws / label / preview
JQ_LIB='
def c(n; s): "\u001b[\(n)m\(s)\u001b[39m";
def dim(s): c(90; s);
# row colors by kind: workspace, tab number / text, agent name
def wsc(s): "\u001b[1;94m\(s)\u001b[22;39m";
def tabn(s): c(35; s);
def tabc(s): c(36; s);
def agentc(s): "\u001b[38;5;215m\(s)\u001b[39m";
def icon: {working: c(33; "●"), blocked: c(31; "▲"), done: c(32; "✓"),
           idle: c(32; "○")}[.] // " ";
def home: sub("^" + env.HOME; "~");
def base: split("/") | map(select(. != "")) | last // "/";
# the pane a tab shows: its focused pane, else its first
def tab_pane($s): . as $id | [$s.panes[] | select(.tab_id == $id)] |
    (first(.[] | select(.focused)) // first(.[]) // {});
def agents($s): . as $id | [$s.panes[] | select(.tab_id == $id) | .agent // empty] | unique;
def pane_text: if .agent then agentc(.agent)
    else .terminal_title_stripped // ((.foreground_cwd // .cwd // "") | base) end;
def tab_text($s): (.tab_id | agents($s)) as $a | (.tab_id | tab_pane($s)) as $p |
    if ($a | length) > 0 then $a | map(agentc(.)) | join(", ")
    else tabc($p.terminal_title_stripped // (($p.foreground_cwd // "") | base)) end;
# 1-based position of a tab within its workspace, in `herdr tab list` order
# (the agent-tabs plugin renames labels to this; .number is a creation counter)
def tab_pos($s): . as $id
    | [$s.tabs[] | select(.workspace_id == ($id | split(":")[0])) | .tab_id] as $ids
    | (($ids | index($id)) // 0) + 1;
'

list_ws() {
    state | jq -r --arg pad "$SEARCH_PAD" "$JQ_LIB"'
        . as $s | .ws[] | . as $w
        | [$s.tabs[] | select(.workspace_id == $w.workspace_id)] as $tabs
        | "\($pad)\($w.label) \($w.active_tab_id | tab_pane($s) | .cwd // "" | home)" as $q
        | ([$tabs[].tab_id | agents($s)[]] | unique) as $agents
        | ([$s.panes[] | select(.workspace_id == $w.workspace_id)] | length) as $npanes
        | ([ dim("tabs \($tabs | length): panes \($npanes)"),
             (if ($agents | length) > 0 then $agents | map(agentc(.)) | join(dim(", ")) else empty end),
             (if $w.focused then dim("current") else empty end) ] | join(dim(" · "))) as $meta
        | "\(wsc($w.label))\(if $meta != "" then "  " + $meta else "" end)\tws\t\($w.workspace_id)\t\($q)",
          ($tabs | to_entries[] | .value as $t
           | (.key == ($tabs | length) - 1) as $last
           | [$s.panes[] | select(.tab_id == $t.tab_id)] as $splits
           | "  \(dim(if $last then "└" else "├" end)) \($t.agent_status | icon) \(tabn($t.tab_id | tab_pos($s) | tostring)) \($t | tab_text($s))\(if ($splits | length) > 1 then "  " + dim("\($splits | length) splits") else "" end)\(if $t.tab_id == $w.active_tab_id then " " + dim("•") else "" end)\ttab\t\($t.tab_id)\t\($q)",
             ($splits | to_entries[] | .value as $p
              | "  \(if $last then " " else dim("│") end)   \(dim(if .key == ($splits | length) - 1 then "└" else "├" end)) \(dim("⠿")) \($p.agent_status | icon) \($p | pane_text)  \(dim($p.pane_id | split(":") | last))\tpane\t\($p.pane_id)\t\($q)"))'
}

# one row per agent pane; the ones that need you first
list_agents() {
    state | jq -r --arg pad "$SEARCH_PAD" "$JQ_LIB"'
        . as $s
        | {blocked: 0, done: 1, working: 2, idle: 3} as $rank
        | [.panes[] | select(.agent)] | sort_by($rank[.agent_status] // 4, .pane_id)
        | if length == 0 then dim("no agents running") + "\tnone\t" else .[] end
        | if type == "string" then . else
            . as $p
            | first($s.ws[] | select(.workspace_id == $p.workspace_id)) as $w
            | first($s.tabs[] | select(.tab_id == $p.tab_id)) as $t
            | "\($p.agent_status | icon) \(wsc($w.label)) \(dim("›")) \(tabn($t.tab_id | tab_pos($s) | tostring))  \(agentc($p.agent))  \(dim($p.terminal_title_stripped // ""))\tagent\t\($p.pane_id)\t\($pad)\($w.label)"
          end'
}

# labels / cwds of live workspaces (to hide duplicate cfg / dir entries)
live_labels() { herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.label'; }
live_cwds() { herdr pane list 2>/dev/null | jq -r '.result.panes[]?.cwd // empty' | sort -u; }

list_cfg() {
    local live cwds
    live="$(live_labels)"
    cwds="$(live_cwds)"
    sesh list -c --icons 2>/dev/null | while IFS= read -r line; do
        name="$(printf '%s' "$line" | perl -pe 's/\e\[[0-9;]*m//g; s/^\S+\s+//')"
        grep -qxF -- "$name" <<<"$live" && continue
        grep -qxF -- "$(expand "$(sesh_field "$name" path)")" <<<"$cwds" && continue
        # keep sesh's icon, the name in yellow
        printf '%s\e[33m%s\e[39m  \e[90msaved\e[39m\tcfg\t%s\t%s%s\n' "${line%%"$name"*}" "$name" "$name" "$SEARCH_PAD" "$name"
    done
}

# zoxide dirs, cleaned up: resolved (/tmp = /private/tmp, scores summed),
# existing only, minus open workspaces / sesh.toml paths. MODE all = frecent
# ones (score >= DIRS_MIN_SCORE or a git root, top DIRS_MAX) first, the rest
# tagged "more" (shown only when searching); full = every one, with its score.
list_dir() {
    zoxide query -ls 2>/dev/null | python3 -c '
import os, sys, tomllib
mode, min_score, max_n, toml, live = sys.argv[1:]
home = os.path.expanduser("~")
skip = {os.path.realpath(p) for p in live.splitlines() if p}
try:
    with open(toml, "rb") as f:
        for sess in tomllib.load(f).get("session", []):
            skip.add(os.path.realpath(os.path.expanduser(sess.get("path", ""))))
except OSError:
    pass
dirs = {}  # realpath -> [summed score, shortest spelling]
for line in sys.stdin:
    score, _, path = line.strip().partition(" ")
    path = path.strip()
    if not os.path.isdir(path):
        continue
    d = dirs.setdefault(os.path.realpath(path), [0.0, path])
    d[0] += float(score)
    if len(path) < len(d[1]):
        d[1] = path
rows = sorted(((sc, p, r) for r, (sc, p) in dirs.items() if r not in skip), reverse=True)
top = set()
if mode == "all":
    top = [x for x in rows
           if x[0] >= float(min_score) or os.path.exists(os.path.join(x[2], ".git"))]
    top = top[: int(max_n)]
    rows = top + [x for x in rows if x not in top]
    top = set(top)
for sc, p, r in rows:
    shown = "~" + p[len(home):] if p == home or p.startswith(home + "/") else p
    if shown.startswith("/private/"):  # macOS: /tmp, /var are links into /private
        shown = shown[len("/private"):]
    tag = f"{sc:g}" if mode == "full" else "recent"
    more = "\tmore" if mode == "all" and (sc, p, r) not in top else ""
    print(f"\033[36m\033[39m {shown}  \033[90m{tag}\033[39m\tdir\t{p}\t{" " * 1000}{p}{more}")
' "${1:-all}" "$DIRS_MIN_SCORE" "$DIRS_MAX" "$SESH_TOML" "$(live_cwds)"
}

list_find() {
    local base
    base="$(current_dir)"
    [ -d "$base" ] || base="$HOME"
    fd -H -d 2 -t d -E .Trash -E .git -E node_modules . "$base" 2>/dev/null |
        while IFS= read -r d; do
            d="${d%/}"
            printf '\e[33m\e[39m %s\tdir\t%s\t%s%s\n' "${d/#$HOME/\~}" "$d" "$SEARCH_PAD" "$d"
        done
}

# MODE may be a picker prompt ("dirs › ")
list() {
    local mode="${1:-all}"
    case "${mode%% *}" in
    ws) list_ws ;;
    agents) list_agents ;;
    cfg) list_cfg ;;
    dirs) list_dir full ;;
    browse) list_find ;;
    *)
        list_ws
        list_cfg
        list_dir all
        ;;
    esac
}

# the pane shown for a ws/tab entry, as JSON {pane, ws, tab}
entry_pane() {
    state | jq -c --arg kind "$1" --arg id "$2" "$JQ_LIB"'
        . as $s
        | (if $kind == "agent" or $kind == "pane" then first($s.panes[] | select(.pane_id == $id))
           else null end) as $ap
        | (if $kind == "tab" then $id
           elif $ap then $ap.tab_id
           else first($s.ws[] | select(.workspace_id == $id) | .active_tab_id) end) as $tid
        | {pane: ($ap // ($tid | tab_pane($s))),
           tab: first($s.tabs[] | select(.tab_id == $tid)),
           position: ($tid | tab_pos($s)),
           ws: first($s.ws[] | select(.workspace_id == ($tid | split(":")[0])))}'
}

preview() {
    local kind target pane
    kind="$(field "$1" 2)"
    target="$(field "$1" 3)"
    case "$kind" in
    ws | tab | agent | pane)
        pane="$(entry_pane "$kind" "$target" | jq -r '.pane.pane_id // empty')"
        [ -n "$pane" ] && herdr pane read "$pane" --source visible --format ansi 2>/dev/null ||
            echo "(no preview)"
        ;;
    cfg | dir) sesh preview "$target" 2>/dev/null || ls -la "$(expand "$target")" ;;
    *) echo "(no preview)" ;;
    esac
}

# preview border label: " ws › tab N · agent · status · cwd "
label() {
    local kind target
    kind="$(field "$1" 2)"
    target="$(field "$1" 3)"
    case "$kind" in
    ws | tab | agent | pane)
        entry_pane "$kind" "$target" | jq -r "$JQ_LIB"'
                [ .ws.label + (if (.ws.tab_count // 1) > 1 then " › tab \(.position)" else "" end),
                  (.pane.agent // empty),
                  (if (.pane.agent_status // "unknown") != "unknown" then .pane.agent_status else empty end),
                  ((.pane.foreground_cwd // "") | home | select(. != "")) ]
                | " " + join(" · ") + " "'
        ;;
    cfg | dir) printf ' %s ' "$target" ;;
    esac
}

kill_entry() {
    case "$(field "$1" 2)" in
    ws) herdr workspace close "$(field "$1" 3)" >/dev/null 2>&1 || true ;;
    tab) herdr tab close "$(field "$1" 3)" >/dev/null 2>&1 || true ;;
    dir) zoxide remove "$(field "$1" 3)" >/dev/null 2>&1 || true ;;
    esac
}

help() {
    local d=$'\e[90m' b=$'\e[1m' r=$'\e[0m' y=$'\e[33m' g=$'\e[32m' red=$'\e[31m' c=$'\e[36m'
    local B=$'\e[1;94m' m=$'\e[35m' o=$'\e[38;5;215m'
    cat <<EOF
${b}What's in the list${r}

  ${y}●${r} ${B}name${r}        ${b}open${r}    a herdr workspace that is running now
     ├ ${m}2${r} ${o}claude${r}           its tabs, with the agent running in each
     │   ├ ${d}⠿${r} ○ ${o}claude${r}     and each tab's splits (enter focuses the tab)
  ${d}${r} ${y}name${r}  ${d}saved${r}           a session from sesh/sesh.toml: opens a
                          workspace at its path + runs its startup command
  ${c}${r} path  ${d}recent${r}          a directory you use a lot (zoxide):
                          opens a new workspace there

${b}Directories${r}
  all shows only frecent ones: zoxide score >= ${DIRS_MIN_SCORE}, or a git repo,
  top ${DIRS_MAX}; typing searches every one. ^x dirs lists all with scores. ^d on a
  directory forgets it in zoxide for good (also for z / cd).

${b}Moving splits${r}
  drag a ${d}⠿${r} split row with the mouse onto a workspace (→ new tab
  there) or a tab / another split (→ split into that tab). It moves
  as soon as you let go.

${b}Agent status${r}
  ${y}●${r} working   ${g}○${r} idle   ${g}✓${r} done   ${red}▲${r} needs input

${b}Keys${r}
  enter     switch to it (workspace / tab / agent), or create it
  ^s        spaces     only the open herdr workspaces (the start view)
  ^a        all        open workspaces + saved sessions + frecent dirs
  ^m        expand     show every workspace's tabs + splits (drag to move);
                       again to collapse back to one line per workspace
                       (^e does the same where the terminal can't tell ^m from enter)
  ^t        agents     only agents, the ones that need you first
  ^x        dirs       every zoxide directory, with its score
  ^f        browse     folders under the current pane's directory
  ^o        new        scratch workspace (a name → /tmp/name, or a path)
  ^b        web        ask for a URL, open it in a browser workspace
  ^d        close      close workspace / tab, forget a directory
  tab ^n    down       shift-tab ^p   up
  esc       quit       ? this help (move the cursor to go back)
EOF
}

# focus the workspace labelled NAME, or create it in PATH (running CMD once)
connect() {
    local name="$1" path="$2" cmd="${3:-}" id
    id="$(workspace_id_for "$name")"
    if [ -n "$id" ]; then
        herdr workspace focus "$id" >/dev/null
        return
    fi
    [ -d "$path" ] || path="$HOME"
    id="$(herdr workspace create --cwd "$path" --label "$name" --focus 2>/dev/null |
        jq -r '.. | .workspace_id? // empty' | head -1)"
    [ -n "$id" ] || id="$(workspace_id_for "$name")"
    if [ -n "$cmd" ] && [ -n "$id" ]; then
        sleep 0.2
        herdr pane run "$id:p1" "$cmd" >/dev/null
    fi
}

browser() {
    local input host label
    printf 'Website URL: ' >/dev/tty
    IFS= read -r input </dev/tty
    input=${input%/}
    [ -n "$input" ] || exit 0
    host="$(printf '%s' "$input" | sed -E 's#^[a-zA-Z]+://##; s#^www\.##i; s#/.*$##')"
    label="$(printf '%s' "$host" | cut -d. -f1)"
    connect "Browser${label^}" "$HOME" "$HOME/.local/bin/terminal-browser open '$input'"
}

pick() {
    local selected
    selected="$(
        list all | awk -F'\t' '$5 != "more"' | fzf \
            --height 100% --margin 0 --padding 0,1 \
            --ansi --highlight-line --info inline-right \
            --delimiter $'\t' --with-nth 1,4 --nth 2 --no-hscroll --ellipsis '' \
            --border-label ' herdr sessions · ? help ' --prompt 'all › ' \
            --header $'^s spaces  ^a all  ^t agents  ^x dirs\n^o new  ^b web  ^d close/forget  ? help' \
            --bind 'tab:down,btab:up' \
            --bind "ctrl-a:change-prompt(all › )+reload('$SELF' list all)" \
            --bind "ctrl-t:change-prompt(agents › )+reload('$SELF' list agents)" \
            --bind "ctrl-x:change-prompt(dirs › )+reload('$SELF' list dirs)" \
            --bind "ctrl-s:change-prompt(spaces › )+reload('$SELF' list ws)" \
            --bind 'ctrl-o:become($HOME/.dotfiles/sesh/create_scratch.sh)' \
            --bind "ctrl-b:become('$SELF' browser)" \
            --bind "ctrl-d:execute-silent('$SELF' kill {})+reload('$SELF' list \"\$FZF_PROMPT\")" \
            --bind "?:change-preview-label( help )+preview('$SELF' help)" \
            --bind "focus:transform-preview-label('$SELF' label {})" \
            --preview-window 'right,55%,<110(down,50%)' \
            --preview "'$SELF' preview {}"
    )" || selected=""
    [ -z "$selected" ] && exit 0
    act "$selected"
}

# switch to / create what a picker line points at; a bare path (scratch) too
act() {
    local selected="$1" kind target name path
    [ -n "$selected" ] || return 0
    if [[ $selected != *$'\t'* ]]; then
        connect "$(basename "$selected")" "$selected"
        return
    fi

    kind="$(field "$selected" 2)"
    target="$(field "$selected" 3)"
    case "$kind" in
    ws) herdr workspace focus "$target" >/dev/null ;;
    tab) herdr tab focus "$target" >/dev/null ;;
    agent) herdr agent focus "$target" >/dev/null ;;
    pane) # a split: focus its tab
        herdr tab focus "$(herdr pane get "$target" | jq -r '.result.pane.tab_id')" >/dev/null ;;
    cfg)
        path="$(expand "$(sesh_field "$target" path)")"
        connect "$target" "$path" "$(sesh_field "$target" startup_command)"
        ;;
    dir)
        path="$(expand "$target")"
        name="$(basename "$path")"
        connect "$name" "$path"
        ;;
    esac
}

case "${1:-}" in
list) list "${2:-all}" ;;
preview) preview "$2" ;;
label) label "$2" ;;
help) help ;;
kill) kill_entry "$2" ;;
browser) browser ;;
state) state ;;
go) act "${2:-}" ;;
fzf) pick ;;
*)
    if command -v node >/dev/null 2>&1; then
        exec node "$(dirname -- "$SELF")/herdr-picker.mjs"
    fi
    pick
    ;;
esac
