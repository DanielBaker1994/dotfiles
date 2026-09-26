#!/usr/bin/env bash
#
# agent-tabs.sh sync | startup | toggle
#
# Every tab with an agent gets "<status><agent> " in front of its label; the
# prefix is stripped and re-applied on each sync, so a manual rename keeps
# its name and a tab whose agent exits goes back to plain. A label that is
# just a number counts as the default one and follows the tab's number.
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
  "agent.default": "󰧑"
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

# "tab<TAB>TAB_ID<TAB>NEW_LABEL" for every tab whose label must change,
# "meta<TAB>PANE_ID<TAB>PLAIN_LABEL" for every agent pane
plan() {
    jq -rn \
        --argjson icons "$(icons)" \
        --argjson t "$("$herdr" tab list 2>/dev/null || echo '{}')" \
        --argjson p "$("$herdr" pane list 2>/dev/null || echo '{}')" \
        --arg off "$1" '
        def esc: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\\(.c)");
        # + the glyphs of earlier versions, so old prefixes get cleaned up
        ("⚡▲✓○✻⌬◈❂◉▸◎◆π✦◐◑☿◇󰅩" | split("")) as $old
        | ([$icons[], $old[]] | map(select(. != "") | esc) | unique | join("|")) as $any
        | {blocked: 0, done: 1, working: 2, idle: 3} as $rank
        | ($p.result.panes // []) as $panes
        | ($t.result.tabs // [])[] as $tab
        | ($tab.label | sub("^((" + $any + ")+ )+"; "")) as $base
        | (if $base | test("^[0-9]+$") then $tab.number | tostring else $base end) as $base
        | [$panes[] | select(.tab_id == $tab.tab_id and .agent)] as $agents
        | ($agents | sort_by($rank[.agent_status] // 4) | first // null) as $pane
        | (if $off == "1" or $pane == null then ""
           else ($icons["status." + ($tab.agent_status // "")] // "")
                + ($icons[$pane.agent] // $icons["agent.default"] // "")
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
