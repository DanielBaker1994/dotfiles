#!/usr/bin/env bash
#
# agent-tabs.sh sync | focus | startup | toggle   (focus = sync; kept for the manifest)
#
# Every tab with an agent gets "<status> <agent> " in front of its label; the
# prefix is stripped and re-applied on each sync, so a manual rename keeps
# its name and a tab whose agent exits goes back to plain. A label that is
# just a number counts as the default one and follows the tab's position
# in its workspace (1, 2, 3 … with no gaps).
# A tab without an agent gets the icon of its foreground process instead
# (proc.nvim, proc.zsh ... in DEFAULT_ICONS; proc.default for unknown ones).
# Status glyphs are herdr's own (status_indicators = "symbols"); agent icons
# are Nerd Font glyphs (a full cell, bigger than plain Unicode symbols),
# except opencode: ⬓ is its logo (a frame, bottom half filled).
#
# Each agent pane also gets the pane tokens $tab_name = the tab's plain label
# and $agent_icon = its agent's glyph, so the sidebar's agent rows show the
# label without the prefix and an icon in place of the agent's name
# (config.toml [ui.sidebar.agents] rows; colors per agent there), plus $ws =
# the workspace name padded to the longest agent workspace name (capped at
# WS_WIDTH, longer names end in …) so the tab column lines up. herdr trims
# token whitespace, so the padding is U+2800 (braille blank), not spaces.
#
# Glyph overrides: $HERDR_PLUGIN_CONFIG_DIR/icons.conf, lines like
#   claude = ✻
#   status.working = ●
# State ($HERDR_PLUGIN_STATE_DIR): off = indicators turned off;
# meta/PANE_ID = the $tab_name, $agent_icon, $ws last reported for that pane.

set -euo pipefail
# handler timing -> herdr/herdr-prof.sh (no-op if missing)
# shellcheck source=../prof.sh
source "$HOME/.dotfiles/herdr/plugins/prof.sh" 2>/dev/null || prof_end() { :; }

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-tabs}"
config="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/local.agent-tabs}"
[ -d "$state/meta" ] || mkdir -p "$state/meta"

# widest $ws: sidebar_width 26 minus "○ 󰛄 · " and " · N"
WS_WIDTH=13

DEFAULT_ICONS='{
  "status.blocked": "×", "status.working": "◐", "status.done": "✓",
  "status.idle": "○",
  "claude": "󰛄",
  "opencode": "⬓",
  "devin": "󰚩",
  "codex": "󰙴",
  "copilot": "󰊤",
  "cursor": "󰆍",
  "agent.default": "󰧑",
  "proc.nvim": "",
  "proc.vim": "",
  "proc.zsh": "",
  "proc.bash": "",
  "proc.fish": "",
  "proc.sh": "",
  "proc.lazygit": "",
  "proc.git": "",
  "proc.ssh": "󰣀",
  "proc.htop": "",
  "proc.btop": "",
  "proc.node": "",
  "proc.python": "",
  "proc.python3": "",
  "proc.default": ""
}'

# A tab switch sends several events at once. Only one run works at a time;
# an event that finds one running leaves a pending mark and exits, and the
# running one goes round again for all of them, so a burst costs two runs at
# most instead of a queue of one per event. The lock is a symlink to the
# holder's pid: a run that was killed holding it (pid gone) gets taken over.
lock="$state/.lock-pid"
take_lock() {
    local pid
    ln -s "$$" "$lock" 2>/dev/null && return 0
    pid="$(readlink "$lock" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null && return 1
    rm -f "$lock"
    ln -s "$$" "$lock" 2>/dev/null
}

icons_user() {
    if [ -f "$config/icons.conf" ]; then
        jq -R -s '
            split("\n") | map(select(test("^\\s*[^#\\s]")) | capture("^\\s*(?<k>[^=\\s]+)\\s*=\\s*(?<v>.*?)\\s*$"))
            | map({(.k): .v}) | add // {}' "$config/icons.conf"
    else
        echo '{}'
    fi
}

# {"PANE_ID": "process"} for the non-agent panes: the foreground process
# group leader (process-info also lists children, e.g. nvim's language servers).
# process-info is one CLI round trip per pane (~65 ms each on the work Mac,
# 48 panes = 3 s), and herdr has no batch form, so only these are asked: the
# focused tab's panes and panes not in the cache ($state/procs.json, from
# earlier runs). The rest keep their cached process; it changes only when
# you run something in that pane, and you see it the next time you focus it.
# `procs PANES 1` asks every pane (startup, toggle, no cache yet).
procs() {
    local id cache=/dev/null
    [ "${2:-}" != 1 ] && [ -s "$state/procs.json" ] && cache="$state/procs.json"
    jq -r --slurpfile cache "$cache" '
        ($cache[0] // null) as $c
        | ([.result.panes[]? | select(.focused)][0].tab_id) as $ft
        | .result.panes[]? | select(.agent | not) | .pane_id as $id
        | select($c == null or .tab_id == $ft or ($c | has($id) | not)) | $id' <<<"$1" |
        while read -r id; do
            printf '%s\t' "$id"
            "$herdr" pane process-info --pane "$id" 2>/dev/null || echo null
        done |
        jq -R -n --slurpfile cache "$cache" --argjson p "$1" '
            [$p.result.panes[]? | select(.agent | not) | .pane_id] as $live
            # cached entries for panes that still exist and still have no agent
            | (($cache[0] // {}) | with_entries(select(.key as $k | $live | index($k))))
            # "" = asked, no process found: cached too, so it is not re-asked every run
            + ([inputs | select(. != "") | split("\t") as [$id, $json]
                | ($json | fromjson? // null | .result.process_info) as $pi
                | {($id): (if $pi == null then ""
                           else ($pi.foreground_process_group_id as $g | $pi.foreground_processes
                                 | (map(select(.pid == $g))[0] // .[0]).name // "") end)}]
               | add // {})'
}

# "tab<TAB>TAB_ID<TAB>NEW_LABEL" for every tab whose label must change,
# "meta<TAB>PANE_ID<TAB>PLAIN_LABEL<TAB>AGENT_ICON<TAB>PADDED_WS" for every agent pane
plan() {
    local p procs
    p="$("$herdr" pane list 2>/dev/null || echo '{}')"
    procs="$(procs "$p" "$2")"
    printf '%s' "$procs" >"$state/procs.json.$$" && mv -f "$state/procs.json.$$" "$state/procs.json"
    jq -rn \
        --argjson d "$DEFAULT_ICONS" \
        --argjson u "$(icons_user)" \
        --argjson t "$("$herdr" tab list 2>/dev/null || echo '{}')" \
        --argjson p "$p" \
        --argjson procs "$procs" \
        --argjson w "$("$herdr" workspace list 2>/dev/null || echo '{}')" \
        --argjson wsw "$WS_WIDTH" \
        --arg off "$1" '
        def ws($n): if length > $n then .[:$n - 1] + "…" else . + ("⠀" * ($n - length)) end;
        def esc: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\\(.c)");
        ($d + $u) as $icons
        # + the glyphs of earlier versions, so old prefixes get cleaned up
        | ("⚡▲✓○✻⌬◈❂◉▸◎◆π✦◐◑☿◇󰅩" | split("")) as $old
        | ([$icons[], $old[]] | map(select(. != "") | esc) | unique | join("|")) as $any
        | {blocked: 0, done: 1, working: 2, idle: 3} as $rank
        | ($p.result.panes // []) as $panes
        | ($t.result.tabs // []) as $tabs
        | ($w.result.workspaces // [] | map({(.workspace_id): .label}) | add // {}) as $wsname
        | ([$panes[] | select(.agent) | $wsname[.workspace_id] // "" | length] | max // 0
           | [., $wsw] | min) as $width
        # position within its workspace (list order = cmd+N order); herdr'"'"'s
        # own .number is a creation counter that keeps gaps after moves/closes
        | (reduce $tabs[] as $x ({n: {}, pos: {}};
             .n[$x.workspace_id] += 1 | .pos[$x.tab_id] = .n[$x.workspace_id]) | .pos) as $pos
        | $tabs[] as $tab
        | ($tab.label | sub("^((" + $any + ")+ )+"; "")) as $base
        | (if $base | test("^[0-9]+$") then $pos[$tab.tab_id] | tostring else $base end) as $base
        | [$panes[] | select(.tab_id == $tab.tab_id and .agent)] as $agents
        | ($agents | sort_by($rank[.agent_status] // 4) | first // null) as $pane
        # tab without an agent: icon of the foreground process (focused pane first)
        | ([$panes[] | select(.tab_id == $tab.tab_id)] | sort_by(.focused | not) | first // null) as $np
        | (if $np == null then "" else $procs[$np.pane_id] // "" end) as $proc
        | (if $off == "1" then ""
           elif $pane == null then
             ($icons["proc." + $proc] // $icons["proc.default"] // "")
           else [($icons["status." + ($tab.agent_status // "")] // ""),
                 ($icons[$pane.agent] // $icons["agent.default"] // "")]
                | map(select(. != "")) | join(" ")
           end) as $prefix
        | (if $prefix == "" then $base else $prefix + " " + $base end) as $label
        | (if $label != $tab.label then "tab\t\($tab.tab_id)\t\($label)" else empty end),
          ($agents[] | "meta\t\(.pane_id)\t\($base)\t\($icons[.agent] // $icons["agent.default"])\t\($wsname[.workspace_id] // "" | ws($width))")'
}

# sync [1]: 1 = ask every pane for its process (see procs)
sync() {
    local off=0 kind id label icon ws seen=" " last
    [ -e "$state/off" ] && off=1
    while IFS=$'\t' read -r kind id label icon ws; do
        case "$kind" in
            tab) "$herdr" tab rename "$id" "$label" >/dev/null 2>&1 || true ;;
            meta)
                seen+="$id "
                # builtin read, not $(cat): this runs for every agent pane on every focus
                last=""
                IFS= read -r last 2>/dev/null <"$state/meta/$id" || true
                [ "$last" = "$label $icon $ws" ] && continue
                # pane id first: herdr 0.9 rejects options before it
                "$herdr" pane report-metadata "$id" --source agent-tabs \
                    --token "tab_name=$label" --token "agent_icon=$icon" --token "ws=$ws" \
                    >/dev/null 2>&1 && printf '%s' "$label $icon $ws" >"$state/meta/$id"
                ;;
        esac
    done < <(plan "$off" "${1:-}")
    # forget panes that are gone or no longer run an agent
    for f in "$state/meta"/*; do
        [ -e "$f" ] || continue
        [[ $seen == *" ${f##*/} "* ]] || rm -f "$f"
    done
}

# pending marks: .pending-full (every pane's process asked) wins over .pending
mode="${1:-sync}"
case "$mode" in
    startup | toggle) : >"$state/.pending-full" ;;
    *) : >"$state/.pending" ;;
esac
case "$mode" in
    # a server start drops pane metadata: report every $tab_name again
    startup) rm -f "$state/meta"/* ;;
    toggle) if [ -e "$state/off" ]; then rm -f "$state/off"; else : >"$state/off"; fi ;;
esac

trap 'prof_end' EXIT
while take_lock; do
    trap 'rm -f "$lock"; prof_end' EXIT
    while :; do
        if [ -e "$state/.pending-full" ]; then
            rm -f "$state/.pending-full" "$state/.pending"
            sync 1
        elif [ -e "$state/.pending" ]; then
            rm -f "$state/.pending"
            sync
        else
            break
        fi
    done
    rm -f "$lock"
    trap 'prof_end' EXIT
    # an event that came in after the last check but before the lock was
    # dropped found it held and left only its mark: go round for it
    [ -e "$state/.pending-full" ] || [ -e "$state/.pending" ] || break
done
