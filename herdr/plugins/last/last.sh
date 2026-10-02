#!/usr/bin/env bash
#
# last.sh record | workspace | tab
#
# tmux-style "last" jumps, driven by Herdr's focus events.
#
# State (HERDR_PLUGIN_STATE_DIR):
#   ws            "CURRENT PREVIOUS" workspace ids
#   tab-<ws>      "CURRENT PREVIOUS" tab ids inside that workspace
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

record() {
    [ -n "${HERDR_WORKSPACE_ID:-}" ] || return 0
    push ws "$HERDR_WORKSPACE_ID"
    [ -n "${HERDR_TAB_ID:-}" ] && push "tab-$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID"
}

jump() {
    local file="$1" kind="$2" cur prev
    read -r cur prev <<<"$(read_pair "$file")" || true
    [ -n "${prev:-}" ] || return 0
    "$herdr" "$kind" focus "$prev" >/dev/null 2>&1 || true
}

case "${1:-}" in
    record) record ;;
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
esac
