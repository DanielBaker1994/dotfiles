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
# handler timing -> herdr/herdr-prof.sh (no-op if missing)
# shellcheck source=../prof.sh
source "$HOME/.dotfiles/herdr/plugins/prof.sh" 2>/dev/null || true

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-last}"
[ -d "$state" ] || mkdir -p "$state"

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
# (prefix match for "ws epoch" lines); keep MAX lines
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

# Keep the sidebar's spaces ordered by most recent access: the workspace that
# just took focus moves to the top. herdr's CLI has no move command, so this
# speaks the socket API (workspace.move). Only when the workspace changed.
move_to_top() {
    local sock="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
    printf '{"id":"last-top","method":"workspace.move","params":{"workspace_id":"%s","insert_index":0}}\n' "$1" |
        nc -U -w1 "$sock" >/dev/null 2>&1 || true
}

record() {
    [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 0
    local top=""
    read -r top _ 2>/dev/null <"$state/mru" || true
    [ "$top" = "$HERDR_WORKSPACE_ID" ] || move_to_top "$HERDR_WORKSPACE_ID"
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
