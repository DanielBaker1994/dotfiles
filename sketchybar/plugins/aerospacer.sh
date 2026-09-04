#!/usr/bin/env bash

source "$HOME/.config/sketchybar/colors.sh"

RED=0xff8fc4e8
BLUE=0xff9fc8e8
SILVER_BLUE=0xffb8cfe0
SPACE_BG_ACTIVE=0xff4a7180
SPACE_BG_INACTIVE=0xcc1B2736
SPACE_BORDER_COLOR=0xff9fc8e8
SPACE_BORDER_WIDTH=1
GROUP_BORDER_COLOR=0xccb8cfe0
GROUP_BORDER_WIDTH=1
GROUP_CORNER_RADIUS=8
GROUP_HEIGHT=30
GROUP_BG_COLOR=0x883f4a5a
# Symmetric inset between the group border and the pills, on all four sides.
GROUP_EDGE=2

SPACE_CORNER_RADIUS=6
SPACE_WIDTH=70
SPACE_HEIGHT=24
SPACE_GAP=4
SPACE_ICON_PAD_L=4
SPACE_ICON_Y=6
SPACE_LABEL_PAD_R=10
SPACE_LABEL_Y=-4
SPACE_NUMBER_FONT="SF Pro:Bold:9.0"
SPACE_APP_FONT_SIZE=9.0
APP_FONT="sketchybar-app-font:Regular:$SPACE_APP_FONT_SIZE"
MAX_ICONS=3
MONITOR_UPDATE_FREQ=2
# Bar order (AeroSpace lists workspaces alphabetically, which we don't want).
SPACE_ORDER=(M Y W 1 2 3 4 5 6 7 8 9)

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
ICON_MAP="$HOME/.config/sketchybar/sketchybar-app-font/dist/icon_map.json"

# One aerospace call + one python pass for every workspace, then one batched
# sketchybar invocation: the old per-pill scripts spawned ~70 processes per
# workspace switch and applied pills one by one as each finished.
refresh_all() {
    local focused sid glyphs styles="" windows
    focused=${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused 2>/dev/null)}
    windows=$(aerospace list-windows --all --format '%{app-name} %{workspace}' 2>/dev/null)
    while IFS=$'\t' read -r sid glyphs; do
        if [ "$sid" = "$focused" ]; then
            styles+=" --set space.$sid background.color=$SPACE_BG_ACTIVE background.border_width=$SPACE_BORDER_WIDTH background.border_color=$SPACE_BORDER_COLOR icon.highlight=on"
        else
            styles+=" --set space.$sid background.color=$SPACE_BG_INACTIVE background.border_width=0 background.border_color=$SPACE_BORDER_COLOR icon.highlight=off"
        fi
        if [ -n "$glyphs" ]; then
            styles+=" label=$glyphs label.drawing=on"
        else
            styles+=" label= label.drawing=off"
        fi
    done < <(python3 - "$ICON_MAP" "$MAX_ICONS" "$windows" "${SPACE_ORDER[@]}" <<'PY'
import json, sys
from collections import OrderedDict

icon_map_path, max_icons, windows, order = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:])
try:
    icon_of = {n.lower(): e["iconName"]
               for e in json.load(open(icon_map_path)) for n in e["appNames"]}
except Exception:
    icon_of = {}
# Apps without their own glyph: approximate with a close lookalike before
# falling back to the generic :default: tile.
icon_approx = {"webex": ":microsoft_teams:",
               "webex meetings": ":microsoft_teams:",
               "cisco webex": ":microsoft_teams:"}
apps = OrderedDict((sid, OrderedDict()) for sid in order)
for line in windows.splitlines():
    # workspace is the last field: app names may contain spaces, workspace ids never do
    app, _, sid = line.rpartition(" ")
    if app and sid in apps:
        apps[sid][app] = None
for sid in order:
    glyphs, count = "", 0
    for app in apps[sid]:
        # :default: is the generic app glyph; use it when an app has no
        # specific icon in the map instead of rendering nothing
        glyph = icon_of.get(app.lower()) or icon_approx.get(app.lower()) \
            or ":default:"
        if count < max_icons:
            glyphs += glyph
            count += 1
        else:
            glyphs += "…"
            break
    print(f"{sid}\t{glyphs}")
PY
)
    # unquoted on purpose: one batched command, every token is space-free
    [ -n "$styles" ] && sketchybar $styles
}

build_all() {
    local sid
    sketchybar --add event aerospace_workspace_change
    sketchybar --add event aerospace_focus_change
    sketchybar --remove '/^space\./' --remove spaces_monitor --remove workspaces

    sketchybar --add item space.lead left \
        --set space.lead width=$GROUP_EDGE \
        padding_left=0 padding_right=0 \
        background.drawing=off icon.drawing=off label.drawing=off

    for sid in "${SPACE_ORDER[@]}"; do
        sketchybar --add item "space.$sid" left \
            --set "space.$sid" \
            icon="$sid" \
            icon.font="$SPACE_NUMBER_FONT" \
            icon.color=$LABEL_COLOR \
            icon.highlight_color=$BLUE \
            icon.padding_left=$SPACE_ICON_PAD_L \
            icon.y_offset=$SPACE_ICON_Y \
            label.font="$APP_FONT" \
            label.color=$LABEL_COLOR \
            label.padding_left=0 \
            label.padding_right=$SPACE_LABEL_PAD_R \
            label.y_offset=$SPACE_LABEL_Y \
            width=$SPACE_WIDTH \
            background.corner_radius=$SPACE_CORNER_RADIUS \
            background.height=$SPACE_HEIGHT \
            background.padding_left=$((SPACE_GAP / 2)) \
            background.padding_right=$((SPACE_GAP / 2)) \
            background.shadow.drawing=on \
            background.shadow.color=0x60000000 \
            background.shadow.distance=2 \
            background.drawing=on \
            click_script="aerospace workspace $sid"
    done

    sketchybar --add item space.tail left \
        --set space.tail width=$GROUP_EDGE \
        padding_left=0 padding_right=0 \
        background.drawing=off icon.drawing=off label.drawing=off

    sketchybar --add bracket workspaces '/^space\./' \
        --set workspaces \
        background.drawing=on \
        background.color=$GROUP_BG_COLOR \
        background.border_color=$GROUP_BORDER_COLOR \
        background.border_width=$GROUP_BORDER_WIDTH \
        background.corner_radius=$GROUP_CORNER_RADIUS \
        background.height=$GROUP_HEIGHT \
        background.padding_left=0 \
        background.padding_right=0

    sketchybar --add item spaces_monitor left \
        --subscribe spaces_monitor aerospace_workspace_change \
        --set spaces_monitor \
        drawing=off \
        updates=on \
        update_freq=$MONITOR_UPDATE_FREQ \
        script="$CONFIG_DIR/plugins/aerospacer.sh"

    refresh_all
}

# Safety net: the periodic tick re-runs the same single-pass refresh, so a
# highlight lost to a fast workspace toggle is corrected within
# MONITOR_UPDATE_FREQ seconds.
case "$SENDER" in
mouse.clicked)
    case "$NAME" in
    space.*) aerospace workspace "${NAME#space.}" ;;
    esac
    ;;
*)
    if [ "$NAME" = "spaces_monitor" ]; then
        refresh_all
    else
        build_all
    fi
    ;;
esac
