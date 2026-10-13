#!/usr/bin/env bash
#
# last.sh record | workspace | tab | agent-record | agent
#
# tmux-style "last" jumps, driven by Herdr's focus events.
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

record() {
    [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 0
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

case "${1:-}" in
    record) record ;;
    # pane.focused: keep the last agent pane (no-op for plain shell panes)
    agent-record) record_agent ;;
    workspace)
        record
        jump ws workspace
        ;;
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
