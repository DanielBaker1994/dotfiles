#!/usr/bin/env bash
#
# last.sh record | workspace | tab | agent-record | agent | app-focus | from-ks
#
# tmux-style "last" jumps, driven by Herdr's focus events.
#
# prefix+L also crosses into kitchen-sink (the link bank): a shared "places"
# history (PLACES, newest first, no duplicates) holds
#   herdr:<ws>   a herdr workspace (recorded on focus, like `ws` below)
#   ks           kitchen-sink took focus     (AeroSpace on-focus-changed → app-focus)
#   term         Ghostty took focus          (same hook)
# `workspace` goes to the first entry that is neither the current workspace
# nor `term`: kitchen-sink when you came from there, else the last workspace.
# `from-ks` (kitchen-sink's Ctrl+B Shift+L) goes to the newest herdr entry.
#
# State (HERDR_PLUGIN_STATE_DIR):
#   ws            "CURRENT PREVIOUS" workspace ids
#   tab-<ws>      "CURRENT PREVIOUS" tab ids inside that workspace
#   agent         "CURRENT PREVIOUS" agent pane ids (pane.focused)
#   mru           "WORKSPACE EPOCH" lines, most recently focused first (picker sort + "last" column)
#
# Herdr injects HERDR_WORKSPACE_ID / HERDR_TAB_ID for focus events and action
# commands, so recording is just two file writes (no CLI round-trip). Only the
# actual jump shells out, once.

set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-last}"
mkdir -p "$state"
places="${HERDR_LINK_PLACES:-${XDG_STATE_HOME:-$HOME/.local/state}/link-bank/places}"
herdr_pick="${HERDR_PICK_BIN:-$HOME/.dotfiles/sesh/bin/herdr-pick}"

read_pair() { cat "$state/$1" 2>/dev/null || true; }

# push NEW onto the "CURRENT PREVIOUS" pair in FILE (atomic replace)
push() {
    local file="$1" new="$2" cur prev
    read -r cur prev <<<"$(read_pair "$file")" || true
    [ "$new" = "${cur:-}" ] && return
    printf '%s %s\n' "$new" "${cur:-}" >"$state/$file.tmp.$$"
    mv -f "$state/$file.tmp.$$" "$state/$file"
}

# move WS to the top of the mru list (kept to 100 entries)
push_mru() {
    { printf '%s %s\n' "$1" "$(date +%s)"; grep -v -- "^$1 " "$state/mru" 2>/dev/null || true; } | head -100 >"$state/mru.tmp.$$"
    mv -f "$state/mru.tmp.$$" "$state/mru"
}

# move ENTRY to the top of the shared places history (kept to 50 entries)
push_place() {
    mkdir -p "${places%/*}"
    { printf '%s\n' "$1"; grep -vxF -- "$1" "$places" 2>/dev/null || true; } | head -50 >"$places.tmp.$$"
    mv -f "$places.tmp.$$" "$places"
}

record() {
    [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 0
    push_place "herdr:$HERDR_WORKSPACE_ID"
    push_mru "$HERDR_WORKSPACE_ID"
    push ws "$HERDR_WORKSPACE_ID"
    [ -n "${HERDR_TAB_ID:-}" ] && push "tab-$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID"
}

# pane.focused: remember the pane when it hosts an agent. Plain shell panes
# leave the pair alone, so "last agent" stays the most recent agent even when
# you detour through a shell.
record_agent() {
    local ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}" kind="" pane=""
    [ -n "$ctx" ] && kind="$(jq -r '.focused_pane_agent // empty' <<<"$ctx" 2>/dev/null || true)"
    [ -n "$kind" ] || return 0
    pane="${HERDR_PANE_ID:-}"
    [ -n "$pane" ] || pane="$(jq -r '.focused_pane_id // empty' <<<"$ctx" 2>/dev/null || true)"
    [ -n "$pane" ] && push agent "$pane"
}

# true when PANE still hosts an agent (a closed or exited one must not win
# over the other pane in the pair)
is_agent_pane() {
    "$herdr" pane list 2>/dev/null |
        jq -e --arg p "$1" '.result.panes[]? | select(.pane_id == $p) | has("agent")' >/dev/null 2>&1
}

jump() {
    local file="$1" kind="$2" cur prev
    read -r cur prev <<<"$(read_pair "$file")" || true
    [ -n "${prev:-}" ] || return 0
    if [ "$kind" = "agent" ] && ! is_agent_pane "$prev"; then
        # target is gone: shift the pair (next press tries the other pane)
        push "$file" "${cur:-}"
        return 0
    fi
    "$herdr" "$kind" focus "$prev" >/dev/null 2>&1 || true
}

# AeroSpace focus hook: note kitchen-sink / Ghostty taking focus (other apps
# leave the history alone).
app_focus() {
    local app
    app="$(aerospace list-windows --focused --format '%{app-bundle-id}' 2>/dev/null || true)"
    case "$app" in
        dev.danielbaker.kitchen-sink) push_place ks ;;
        com.mitchellh.ghostty) push_place term ;;
    esac
}

# prefix+L: the place before this one. kitchen-sink → herdr-pick go-ks (its
# last view); a workspace → focus it, dropping it when it is gone. No shared
# history to go to → the herdr-only pair, as before.
jump_place() {
    local cur="herdr:${HERDR_WORKSPACE_ID:-}" p
    while read -r p; do
        case "$p" in
            "$cur" | term | "") continue ;;
            ks)
                "$herdr_pick" go-ks app >/dev/null 2>&1 || true
                return
                ;;
            herdr:*)
                if "$herdr" workspace focus "${p#herdr:}" >/dev/null 2>&1; then return; fi
                grep -vxF -- "$p" "$places" >"$places.tmp.$$" || true
                mv -f "$places.tmp.$$" "$places"
                ;;
        esac
    done < <(cat "$places" 2>/dev/null)
    jump ws workspace
}

# kitchen-sink's Ctrl+B Shift+L: raise Ghostty on the newest herdr workspace
# (Ghostty as it is when there is none).
from_ks() {
    local p
    p="$(grep -m1 '^herdr:' "$places" 2>/dev/null || true)"
    exec "$herdr_pick" go-id "${p#herdr:}"
}

case "${1:-}" in
    record) record ;;
    # pane.focused: keep the last agent pane (no-op for plain shell panes)
    agent-record) record_agent ;;
    workspace)
        record
        jump_place
        ;;
    app-focus) app_focus ;;
    from-ks) from_ks ;;
    tab)
        record
        ws="${HERDR_WORKSPACE_ID:-}"
        if [ -z "$ws" ]; then read -r ws _ <<<"$(read_pair ws)" || true; fi
        if [ -n "$ws" ]; then jump "tab-$ws" tab; fi
        ;;
    agent)
        # The focused pane is the agent we are leaving (if any): record it,
        # then toggle to the one before it. The focus event that follows
        # swaps the pair, so the next press toggles back.
        record
        record_agent
        jump agent agent
        ;;
esac
