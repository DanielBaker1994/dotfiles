#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# connect-herdr.sh — sesh-style picker for herdr (prefix+w popup)
#
#   connect-herdr.sh                 picker (fzf + preview)
#   connect-herdr.sh list [MODE]     entries: all | ws | cfg | dir | find
#   connect-herdr.sh preview LINE    preview for one entry
#   connect-herdr.sh kill LINE       close a herdr workspace
#   connect-herdr.sh browser         prompt for a URL, open it in a workspace
#
# Entry line: DISPLAY<TAB>KIND<TAB>TARGET
#   ws  = live herdr workspace (TARGET = workspace id)
#   cfg = sesh.toml session    (TARGET = session name)
#   dir = directory            (TARGET = path)

set -euo pipefail

SESH_TOML="$HOME/.dotfiles/sesh/sesh.toml"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

workspaces_json() { herdr workspace list 2>/dev/null || echo '{}'; }

# workspace id for a label, empty if none
workspace_id_for() {
    workspaces_json | jq -r --arg l "$1" \
        'first(.result.workspaces[]? | select(.label == $l) | .workspace_id) // empty'
}

# path / startup_command of a sesh.toml session
sesh_field() {
    python3 - "$SESH_TOML" "$1" "$2" <<'PY'
import sys, tomllib
path, name, field = sys.argv[1:]
with open(path, "rb") as f:
    for s in tomllib.load(f).get("session", []):
        if s.get("name") == name:
            print(s.get(field, ""))
            break
PY
}

current_dir() {
    herdr pane current 2>/dev/null | jq -r '.result.pane.foreground_cwd // empty' || true
}

list_ws() {
    workspaces_json | jq -r '.result.workspaces[]? |
        "\u001b[35m\u001b[39m \(.label)\(if .focused then " \u001b[90m(current)\u001b[39m" else "" end)\tws\t\(.workspace_id)"'
}

list_cfg() {
    sesh list -c --icons 2>/dev/null | while IFS= read -r line; do
        name="$(printf '%s' "$line" | perl -pe 's/\e\[[0-9;]*m//g; s/^\S+\s+//')"
        printf '%s\tcfg\t%s\n' "$line" "$name"
    done
}

list_dir() {
    sesh list -z --icons 2>/dev/null | while IFS= read -r line; do
        path="$(printf '%s' "$line" | perl -pe 's/\e\[[0-9;]*m//g; s/^\S+\s+//')"
        printf '%s\tdir\t%s\n' "$line" "$path"
    done
}

list_find() {
    local base
    base="$(current_dir)"
    [ -d "$base" ] || base="$HOME"
    fd -H -d 2 -t d -E .Trash -E .git -E node_modules . "$base" 2>/dev/null |
        while IFS= read -r d; do
            d="${d%/}"
            printf '\e[33m\e[39m %s\tdir\t%s\n' "${d/#$HOME/\~}" "$d"
        done
}

list() {
    case "${1:-all}" in
        ws) list_ws ;;
        cfg) list_cfg ;;
        dir) list_dir ;;
        find) list_find ;;
        *) list_ws; list_cfg; list_dir ;;
    esac
}

field() { printf '%s' "$1" | cut -d$'\t' -f"$2"; }
expand() { local p="$1"; [[ $p == "~"* ]] && p="$HOME${p:1}"; printf '%s' "$p"; }

preview() {
    local kind target
    kind="$(field "$1" 2)"
    target="$(field "$1" 3)"
    case "$kind" in
        ws) herdr pane read "$target:p1" --source visible --format ansi 2>/dev/null ||
            echo "(no preview)" ;;
        cfg | dir) sesh preview "$target" 2>/dev/null || ls -la "$(expand "$target")" ;;
        *) echo "(no preview)" ;;
    esac
}

kill_ws() {
    [ "$(field "$1" 2)" = ws ] && herdr workspace close "$(field "$1" 3)" >/dev/null 2>&1 || true
}

# focus the workspace labelled NAME, or create it in PATH (running CMD once)
connect() {
    local name="$1" path="$2" cmd="${3:-}" id
    id="$(workspace_id_for "$name")"
    if [ -n "$id" ]; then
        herdr workspace focus "$id" >/dev/null
        return
    fi
    [ -d "$path" ] || path="$HOME"
    id="$(herdr workspace create --cwd "$path" --label "$name" --focus 2>/dev/null |
        jq -r '.. | .workspace_id? // empty' | head -1)"
    [ -n "$id" ] || id="$(workspace_id_for "$name")"
    if [ -n "$cmd" ] && [ -n "$id" ]; then
        sleep 0.2
        herdr pane run "$id:p1" "$cmd" >/dev/null
    fi
}

browser() {
    local input host label
    printf 'Website URL: ' >/dev/tty
    IFS= read -r input </dev/tty
    input=${input%/}
    [ -n "$input" ] || exit 0
    host="$(printf '%s' "$input" | sed -E 's#^[a-zA-Z]+://##; s#^www\.##i; s#/.*$##')"
    label="$(printf '%s' "$host" | cut -d. -f1)"
    connect "Browser${label^}" "$HOME" "$HOME/.local/bin/terminal-browser open '$input'"
}

pick() {
    local selected kind target name path
    selected="$(
        list all | fzf \
            --ansi --no-sort \
            --delimiter $'\t' --with-nth 1 \
            --border-label ' sesh ' --prompt '⚡  ' \
            --header '  ^a ⚡ all ^t 🪟 herdr ^g ⚙️ configs ^x 📁 zoxide
  ^b 🌐 browser ^c 📝 scratch ^f 🔎 find ^d 🗑️ kill' \
            --bind 'tab:down,btab:up' \
            --bind "ctrl-a:change-prompt(⚡  )+reload('$SELF' list all)" \
            --bind "ctrl-t:change-prompt(🪟  )+reload('$SELF' list ws)" \
            --bind "ctrl-g:change-prompt(⚙️  )+reload('$SELF' list cfg)" \
            --bind "ctrl-x:change-prompt(📁  )+reload('$SELF' list dir)" \
            --bind "ctrl-f:change-prompt(🔎  )+reload('$SELF' list find)" \
            --bind 'ctrl-c:become($HOME/.dotfiles/sesh/create_scratch.sh)' \
            --bind "ctrl-b:become('$SELF' browser)" \
            --bind "ctrl-d:execute-silent('$SELF' kill {})+reload('$SELF' list ws)" \
            --preview-window 'right:60%' \
            --preview "'$SELF' preview {}"
    )" || selected=""
    [ -z "$selected" ] && exit 0

    # scratch prints a bare path
    if [[ $selected != *$'\t'* ]]; then
        connect "$(basename "$selected")" "$selected"
        exit 0
    fi

    kind="$(field "$selected" 2)"
    target="$(field "$selected" 3)"
    case "$kind" in
        ws) herdr workspace focus "$target" >/dev/null ;;
        cfg)
            path="$(expand "$(sesh_field "$target" path)")"
            connect "$target" "$path" "$(sesh_field "$target" startup_command)"
            ;;
        dir)
            path="$(expand "$target")"
            name="$(basename "$path")"
            connect "$name" "$path"
            ;;
    esac
}

case "${1:-}" in
    list) list "${2:-all}" ;;
    preview) preview "$2" ;;
    kill) kill_ws "$2" ;;
    browser) browser ;;
    *) pick ;;
esac
