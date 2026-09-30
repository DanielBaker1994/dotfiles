#!/usr/bin/env bash
#
# agent-tabs.sh sync | startup | toggle
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
# Each agent pane also gets the pane token $tab_name = the tab's plain label,
# so the sidebar's agent rows show it without the prefix (config.toml
# [ui.sidebar.agents] rows use "$tab_name" instead of "tab").
#
# Glyph overrides: $HERDR_PLUGIN_CONFIG_DIR/icons.conf, lines like
#   claude = ✻
#   status.working = ●
# State ($HERDR_PLUGIN_STATE_DIR): off = indicators turned off;
# meta/PANE_ID = the $tab_name last reported for that pane.

set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-tabs}"
config="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/local.agent-tabs}"
mkdir -p "$state/meta"

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

# status events arrive in bursts; serialize (no flock on macOS)
lock="$state/.lock"
for _ in $(seq 100); do mkdir "$lock" 2>/dev/null && break; sleep 0.02; done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

icons() {
    local user='{}'
    [ -f "$config/icons.conf" ] && user="$(jq -R -s '
        split("\n") | map(select(test("^\\s*[^#\\s]")) | capture("^\\s*(?<k>[^=\\s]+)\\s*=\\s*(?<v>.*?)\\s*$"))
        | map({(.k): .v}) | add // {}' "$config/icons.conf")"
    jq -n --argjson d "$DEFAULT_ICONS" --argjson u "$user" '$d + $u'
}

# {"PANE_ID": "process"} for every non-agent pane: the foreground process
# group leader (process-info also lists children, e.g. nvim's language servers)
procs() {
    local id
    "$herdr" pane list 2>/dev/null | jq -r '.result.panes[]? | select(.agent | not) | .pane_id' |
        while read -r id; do
            "$herdr" pane process-info --pane "$id" 2>/dev/null | jq -r --arg id "$id" '
                .result.process_info | select(. != null)
                | (.foreground_process_group_id as $g | .foreground_processes
                   | (map(select(.pid == $g))[0] // .[0]).name // empty)
                | "\($id)\t\(.)"'
        done | jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}'
}

# "tab<TAB>TAB_ID<TAB>NEW_LABEL" for every tab whose label must change,
# "meta<TAB>PANE_ID<TAB>PLAIN_LABEL" for every agent pane
plan() {
    jq -rn \
        --argjson icons "$(icons)" \
        --argjson t "$("$herdr" tab list 2>/dev/null || echo '{}')" \
        --argjson p "$("$herdr" pane list 2>/dev/null || echo '{}')" \
        --argjson procs "$(procs)" \
        --arg off "$1" '
        def esc: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\\(.c)");
        # + the glyphs of earlier versions, so old prefixes get cleaned up
        ("⚡▲✓○✻⌬◈❂◉▸◎◆π✦◐◑☿◇󰅩" | split("")) as $old
        | ([$icons[], $old[]] | map(select(. != "") | esc) | unique | join("|")) as $any
        | {blocked: 0, done: 1, working: 2, idle: 3} as $rank
        | ($p.result.panes // []) as $panes
        | ($t.result.tabs // []) as $tabs
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
          ($agents[] | "meta\t\(.pane_id)\t\($base)")'
}

sync() {
    local off=0 kind id label seen=" "
    [ -e "$state/off" ] && off=1
    while IFS=$'\t' read -r kind id label; do
        case "$kind" in
            tab) "$herdr" tab rename "$id" "$label" >/dev/null 2>&1 || true ;;
            meta)
                seen+="$id "
                [ "$(cat "$state/meta/$id" 2>/dev/null)" = "$label" ] && continue
                # pane id first: herdr 0.9 rejects options before it
                "$herdr" pane report-metadata "$id" --source agent-tabs --token "tab_name=$label" \
                    >/dev/null 2>&1 && printf '%s' "$label" >"$state/meta/$id"
                ;;
        esac
    done < <(plan "$off")
    # forget panes that are gone or no longer run an agent
    for f in "$state/meta"/*; do
        [ -e "$f" ] || continue
        [[ $seen == *" ${f##*/} "* ]] || rm -f "$f"
    done
}

case "${1:-sync}" in
    sync) sync ;;
    # a server start drops pane metadata: report every $tab_name again
    startup) rm -f "$state/meta"/*; sync ;;
    toggle)
        if [ -e "$state/off" ]; then rm -f "$state/off"; else : >"$state/off"; fi
        sync
        ;;
esac
