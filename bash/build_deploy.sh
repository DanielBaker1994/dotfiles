#!/usr/bin/env bash
set -euo pipefail

# Project layout
HOST_ANCHOR_ROOT="${HOST_ANCHOR_ROOT:-$HOME/jira}"
HOST_ANCHOR_PREFIX="${HOST_ANCHOR_PREFIX:-PROJECT_PREFIX_DASH_INTENTIONAL-}"
HOST_ANCHOR_DEST="${HOST_ANCHOR_DEST:-cpp/src}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
BD_TMP="${TMPDIR:-/tmp}"
LAST_FILE="${BD_LAST_FILE:-${BD_TMP%/}/build_deploy_last.$(id -un)}"
HISTORY_FILE="${BD_HISTORY_FILE:-$SCRIPT_DIR/build_deploy.history}"

RECORDING=0

# Build
BD_BUILD_HOST="${BD_BUILD_HOST:-REMOTE_BUILD_ALIAS}"
BD_BUILD_BASE="${BD_BUILD_BASE:-/tmp/set/this/yourself}"
BD_BUILD_BASHRC="${BD_BUILD_BASHRC:-/path/to/custom/bashrc}"
BD_BUILD_ENV="${BD_BUILD_ENV:-/path/to/build/env/file}"
BD_BUILD_CMD="${BD_BUILD_CMD:-make -j8}"
BD_RSYNC_EXCLUDES="${BD_RSYNC_EXCLUDES:-.git/ .cache/}"

# UAT
BD_UAT_HOST="${BD_UAT_HOST:-}"
BD_UAT_BASE="${BD_UAT_BASE:-where/the/binary/lands/on/UAT}"
BD_BINARY_REL="${BD_BINARY_REL:-}"
BD_UAT_BASHRC="${BD_UAT_BASHRC:-~/.bashrc}"
BD_UAT_ENV="${BD_UAT_ENV:-/path/to/uat/env/file}"
BD_UAT_KILL_CMD="${BD_UAT_KILL_CMD:-}"
BD_UAT_STARTUP_CMD="${BD_UAT_STARTUP_CMD:-}"

say() {
    printf '==> %s\n' "$*"
}

shquote() {
    local s="${1//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

require_set() {
    [[ -n "${!1}" ]] || {
        echo "build_deploy: set $1" >&2
        exit 1
    }
}

record_kv() {
    grep -q "^$1=" "$LAST_FILE" 2>/dev/null ||
        printf '%s=%s\n' "$1" "$2" >>"$LAST_FILE"
}

record_cmd() {
    printf 'CMD %s\n' "$*" >>"$LAST_FILE"
    printf '    $ %s\n' "$*"
}

record_init() {
    RECORDING=1
    : >"$LAST_FILE"
    record_kv WHEN "$(date '+%Y-%m-%d %H:%M:%S')"
    record_kv SUBCMD "$1"
    record_kv START_DIR "$2"
}

on_exit() {
    local rc=$?

    if [[ "$RECORDING" -eq 1 ]]; then
        if [[ "$rc" -eq 0 ]]; then
            record_kv RESULT OK
        else
            record_kv RESULT "FAILED(rc=$rc)"
        fi

        printf '==> last run recorded: %s\n' "$LAST_FILE"

        {
            printf '#### RUN\n'
            cat "$LAST_FILE"
        } >>"$HISTORY_FILE"
    fi
}

trap on_exit EXIT

find_project_root() {
    local dir="${1:-$PWD}"
    local root="$HOST_ANCHOR_ROOT"
    local project

    while [[ "$dir" != "/" ]]; do
        if [[ "$dir" == "$root"/* ]]; then
            project="${dir#"$root"/}"
            project="${project%%/*}"

            if [[ "$project" == "$HOST_ANCHOR_PREFIX"* ]]; then
                printf '%s/%s\n' "$root/$project" "$HOST_ANCHOR_DEST"
                return 0
            fi
        fi

        dir=$(dirname "$dir")
    done

    return 1
}

select_project() {
    local start="$1"
    local root

    root=$(find_project_root "$start") || {
        echo "Could not find $HOST_ANCHOR_ROOT above $start" >&2
        return 1
    }

    fzf --walker-root="$root"
}

prompt_binary() {
    local project="$1"
    local default="${project##*/}"

    read -r -p "Binary [$default]: " BD_BINARY_REL
    BD_BINARY_REL="${BD_BINARY_REL:-$default}"
}

compose_env_cmd() {
    local out=""

    [[ -n "$1" ]] && out="source $1"
    [[ -n "$2" ]] && out="${out:+$out && }$2"

    printf '%s' "${out:-true}"
}

run_remote() {
    record_cmd ssh "$1" "bash -lc '$2'"
    ssh "$1" "bash -lc $(shquote "$2")"
}

do_sync() {
    require_set BD_BUILD_HOST
    require_set BD_BUILD_BASE

    local project="$1"
    local project_name="${project##*/}"
    local remote_dir="${BD_BUILD_BASE%/}/$project_name"

    record_kv PROJECT "$project"
    record_kv PROJECT_NAME "$project_name"
    record_kv REMOTE_BUILD_PATH "$remote_dir"

    say "sync: $project -> $BD_BUILD_HOST:$remote_dir"

    local excludes=()
    local e

    for e in $BD_RSYNC_EXCLUDES; do
        excludes+=(--exclude "$e")
    done

    local rsync_cmd=(
        rsync -avz
        "${excludes[@]}"
        -e ssh
        "$project/"
        "$BD_BUILD_HOST:$remote_dir/"
    )

    record_cmd "${rsync_cmd[@]}"
    "${rsync_cmd[@]}"

    say "sync done"
}

do_build() {
    do_sync "$1"

    local project="$1"
    local remote_dir="${BD_BUILD_BASE%/}/${project##*/}"
    local env_cmd
    env_cmd=$(compose_env_cmd "$BD_BUILD_BASHRC" "$BD_BUILD_ENV")

    say "build: $BD_BUILD_HOST:$remote_dir"

    run_remote \
        "$BD_BUILD_HOST" \
        "cd $(shquote "$remote_dir") && $env_cmd && $BD_BUILD_CMD"

    say "build done"
}

do_kill() {
    require_set BD_UAT_HOST

    record_kv UAT_KILL_COMMAND "$BD_UAT_KILL_CMD"

    [[ -n "$BD_UAT_KILL_CMD" ]] || {
        say "no UAT kill command configured — skipping"
        return
    }

    local env_cmd
    env_cmd=$(compose_env_cmd "$BD_UAT_BASHRC" "$BD_UAT_ENV")

    say "kill: $BD_UAT_HOST"

    run_remote \
        "$BD_UAT_HOST" \
        "$env_cmd && $BD_UAT_KILL_CMD"
}

do_deploy() {
    require_set BD_BUILD_HOST
    require_set BD_UAT_HOST
    require_set BD_UAT_BASE
    require_set BD_BINARY_REL

    local project="$1"
    local project_name="${project##*/}"
    local remote_dir="${BD_BUILD_BASE%/}/$project_name"
    local remote_bin="$remote_dir/$BD_BINARY_REL"

    record_kv PROJECT "$project"
    record_kv PROJECT_NAME "$project_name"
    record_kv REMOTE_BUILD_PATH "$remote_dir"
    record_kv BINARY_REL "$BD_BINARY_REL"
    record_kv UAT_STARTUP_COMMAND "$BD_UAT_STARTUP_CMD"

    do_kill

    say "copy: $BD_BUILD_HOST:$remote_bin -> $BD_UAT_HOST:$BD_UAT_BASE"

    record_cmd scp "$BD_BUILD_HOST:$remote_bin" "$BD_UAT_HOST:$BD_UAT_BASE/"
    scp -q "$BD_BUILD_HOST:$remote_bin" "$BD_UAT_HOST:$BD_UAT_BASE/"

    if [[ -n "$BD_UAT_STARTUP_CMD" ]]; then
        local env_cmd
        env_cmd=$(compose_env_cmd "$BD_UAT_BASHRC" "$BD_UAT_ENV")

        say "startup: $BD_UAT_HOST"

        run_remote \
            "$BD_UAT_HOST" \
            "$env_cmd && $BD_UAT_STARTUP_CMD"
    fi

    say "deploy done"
}

do_all() {
    do_build "$1"
    do_deploy "$1"
}

do_rerun() {
    [[ -f "$LAST_FILE" ]] || {
        echo "build_deploy: no recorded run yet ($LAST_FILE)" >&2
        return 1
    }

    local sub project binary

    sub=$(awk -F= '$1 == "SUBCMD" {print $2; exit}' "$LAST_FILE")
    project=$(awk -F= '$1 == "PROJECT" {print $2; exit}' "$LAST_FILE")
    binary=$(awk -F= '$1 == "BINARY_REL" {print $2; exit}' "$LAST_FILE")

    [[ -n "$project" ]] || {
        echo "build_deploy: last run has no project" >&2
        return 1
    }

    if [[ "$sub" == "build" || "$sub" == "all" ]]; then
        BD_BINARY_REL="$binary"
    fi

    case "$sub" in
    sync) do_sync "$project" ;;
    build) do_build "$project" ;;
    all) do_all "$project" ;;
    *)
        echo "build_deploy: last run is not re-runnable: $sub" >&2
        return 1
        ;;
    esac
}

show_last() {
    [[ -f "$LAST_FILE" ]] || {
        echo "build_deploy: no recorded run yet ($LAST_FILE)" >&2
        return 1
    }

    cat "$LAST_FILE"
}

dispatch() {
    local cmd="$1"
    local start="$2"
    local project

    case "$cmd" in
    sync | build | all)
        project=$(select_project "$start") || {
            echo "Nothing selected, returning"
            return
        }

        record_init "$cmd" "$start"
        record_kv PROJECT "$project"

        if [[ "$cmd" != "sync" ]]; then
            prompt_binary "$project"
            record_kv BINARY_REL "$BD_BINARY_REL"
        fi

        case "$cmd" in
        sync) do_sync "$project" ;;
        build) do_build "$project" ;;
        all) do_all "$project" ;;
        esac
        ;;
    rerun) do_rerun ;;
    last) show_last ;;
    *) usage ;;
    esac
}

menu() {
    local start="$1"
    local choice

    cat <<EOF
build/deploy pipeline
  1) Sync + Build
  2) Sync + Build + Deploy
  3) Sync
  4) Re-run last
  5) Show last
EOF

    read -r -p "> " choice || return

    case "$choice" in
    1) dispatch build "$start" ;;
    2) dispatch all "$start" ;;
    3) dispatch sync "$start" ;;
    4) dispatch rerun "$start" ;;
    5) dispatch last "$start" ;;
    *) echo "Nothing selected" >&2 ;;
    esac
}

usage() {
    cat <<EOF
Usage:
  $0 [sync|build|all|rerun|last] [START_DIR]
EOF
}

main() {
    local cmd="${1:-}"

    case "$cmd" in
    sync | build | all | rerun | last)
        dispatch "$cmd" "${2:-$PWD}"
        ;;
    help)
        usage
        ;;
    "")
        menu "$PWD"
        ;;
    *)
        menu "$cmd"
        ;;
    esac
}

main "$@"
