#!/usr/bin/env bash
#
# last.sh record | workspace | tab
#
# State (HERDR_PLUGIN_STATE_DIR):
#   ws            "CURRENT PREVIOUS" workspace ids
#   tab-<ws>      "CURRENT PREVIOUS" tab ids inside that workspace

set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
state="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-last}"
mkdir -p "$state"

# focus events arrive in bursts; serialize (no flock on macOS)
lock="$state/.lock"
for _ in $(seq 50); do mkdir "$lock" 2>/dev/null && break; sleep 0.02; done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

read_pair() { cat "$state/$1" 2>/dev/null || true; }

# push NEW onto the "CURRENT PREVIOUS" pair in FILE
push() {
    local file="$1" new="$2" cur prev
    read -r cur prev <<<"$(read_pair "$file")" || true
    [ "$new" = "${cur:-}" ] && return
    printf '%s %s\n' "$new" "${cur:-}" >"$state/$file"
}

# drop ids of workspaces/tabs that no longer exist
alive() { "$herdr" tab list 2>/dev/null | jq -e --arg id "$1" \
    'any(.result.tabs[]; .tab_id == $id or .workspace_id == $id)' >/dev/null; }

focused() {
    "$herdr" tab list 2>/dev/null |
        jq -r 'first(.result.tabs[] | select(.focused)) | "\(.workspace_id) \(.tab_id)"'
}

record() {
    local ws tab
    read -r ws tab <<<"$(focused)" || return 0
    [ -n "${ws:-}" ] || return 0
    push ws "$ws"
    push "tab-$ws" "$tab"
}

jump() {
    local file="$1" kind="$2" cur prev
    read -r cur prev <<<"$(read_pair "$file")" || true
    [ -n "${prev:-}" ] && alive "$prev" || return 0
    "$herdr" "$kind" focus "$prev" >/dev/null
}

case "${1:-}" in
    record) record ;;
    workspace) record; jump ws workspace ;;
    tab)
        record
        read -r ws _ <<<"$(focused)"
        jump "tab-$ws" tab
        ;;
esac
