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
# handler timing -> herdr/herdr-prof.sh (no-op if missing)
# shellcheck source=../prof.sh
source "$HOME/.dotfiles/herdr/plugins/prof.sh" 2>/dev/null || true

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-last}"
[ -d "$state" ] || mkdir -p "$state"
places="${HERDR_LINK_PLACES:-${XDG_STATE_HOME:-$HOME/.local/state}/link-bank/places}"
herdr_pick="${HERDR_PICK_BIN:-$HOME/.dotfiles/sesh/bin/herdr-pick}"

# Recording runs on every focus event, so it sticks to builtins: one mv per
# file it changes, nothing for a file that already has the entry on top.
read_pair() { local l=""; read -r l 2>/dev/null <"$state/$1" || true; printf '%s' "$l"; }

# push NEW onto the "CURRENT PREVIOUS" pair in FILE (atomic replace)
push() {
    local file="$1" new="$2" cur="" prev=""
    read -r cur prev 2>/dev/null <"$state/$file" || true
    [ "$new" = "$cur" ] && return
    printf '%s %s\n' "$new" "${cur:-}" >"$state/$file.tmp.$$"
    mv -f "$state/$file.tmp.$$" "$state/$file"
}

# move LINE to the top of FILE, dropping other lines KEEP says match it
# (prefix match for "ws epoch" lines, exact for places); keep MAX lines
to_top() {
    local file="$1" line="$2" key="$3" max="$4" l n=1
    {
        printf '%s\n' "$line"
        while IFS= read -r l && ((n < max)); do
            [[ $l == "$key" || $l == "$key "* ]] && continue
            printf '%s\n' "$l"
            ((n++)) || true
        done 2>/dev/null <"$file" || true
    } >"$file.tmp.$$"
    mv -f "$file.tmp.$$" "$file"
}

# move WS to the top of the mru list (kept to 100 entries), with the time
# it was focused; within the same second it is already right
push_mru() {
    local now="${EPOCHSECONDS:-$(date +%s)}" top=""
    read -r top 2>/dev/null <"$state/mru" || true
    [ "$top" = "$1 $now" ] && return
    to_top "$state/mru" "$1 $now" "$1" 100
}

# move ENTRY to the top of the shared places history (kept to 50 entries)
push_place() {
    local top=""
    read -r top 2>/dev/null <"$places" || true
    [ "$top" = "$1" ] && return
    [ -d "${places%/*}" ] || mkdir -p "${places%/*}"
    to_top "$places" "$1" "$1" 50
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
    # plain string fields of the context JSON: a regex instead of two jq runs
    local ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}" pane=""
    [[ $ctx =~ \"focused_pane_agent\":\"[^\"]+\" ]] || return 0
    pane="${HERDR_PANE_ID:-}"
    if [ -z "$pane" ] && [[ $ctx =~ \"focused_pane_id\":\"([^\"]+)\" ]]; then pane="${BASH_REMATCH[1]}"; fi
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
