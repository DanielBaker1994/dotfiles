#!/usr/bin/env bash
set -uo pipefail

SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_PREFIX="${BACKUP_PREFIX:-/tmp/backup_configs}"

command -v ok   >/dev/null 2>&1 || ok()   { printf '\033[32m  \342\234\224 %s\033[0m\n' "$*"; }
command -v fail >/dev/null 2>&1 || fail() { printf '\033[31m  \342\234\230 %s\033[0m\n' "$*"; }
command -v warn >/dev/null 2>&1 || warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
command -v step >/dev/null 2>&1 || step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
command -v info >/dev/null 2>&1 || info() { printf '\033[2m    %s\033[0m\n' "$*"; }

_sl_usage() {
    printf '%s\n' \
        'symlinks.sh — validate / repair this repo'"'"'s dotfile symlinks' \
        '' \
        '  ./symlinks.sh            report + prompt to fix' \
        '  ./symlinks.sh validate   same' \
        '  ./symlinks.sh --check    read-only; exit 1 if wrong' \
        '  ./symlinks.sh --fix      repair without asking'
}

_sl_manifest() {
    printf '%s\n' \
        "$HOME/.bash_profile|$SL_DIR/bash/.bash_profile" \
        "$HOME/.bashrc|$SL_DIR/bash/.bashrc" \
        "$HOME/.inputrc|$SL_DIR/bash/.inputrc" \
        "$HOME/tmux_connect.sh|$SL_DIR/bash/tmux_connect.sh" \
        "$HOME/.tmux.conf|$SL_DIR/tmux/.tmux.conf" \
        "$HOME/.config/nvim|$SL_DIR/nvim" \
        "$HOME/.config/sesh|$SL_DIR/sesh" \
        "$HOME/.config/starship.toml|$SL_DIR/starship/starship.toml" \
        "$HOME/.config/herdr/config.toml|$SL_DIR/herdr/config.toml" \
        "$HOME/.config/lazygit/config.yml|$SL_DIR/lazygit/config.yml" \
        "$HOME/.config/ghostty|$SL_DIR/ghostty" \
        "$HOME/.gitconfig|$SL_DIR/git/.gitconfig" \
        "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty|$SL_DIR/ghostty/config.ghostty"
}

_sl_stale() {
    printf '%s\n' \
        "$HOME/.kitty" \
        "$HOME/.config/kitty"
}

_sl_build_manifest() {
    MAN_TARGET=()
    MAN_SOURCE=()
    local line t s
    while IFS= read -r line; do
        t="${line%%|*}"
        s="${line#*|}"
        MAN_TARGET+=("$t")
        MAN_SOURCE+=("$s")
    done < <(_sl_manifest)
}

_sl_state() {
    local t="$1" s="$2" rt rs
    [ -e "$s" ] || { printf 'BROKEN'; return; }
    rt="$(cd "$t" 2>/dev/null && pwd -P)"
    rs="$(cd "$s" 2>/dev/null && pwd -P)"
    [ -n "$rt" ] && [ "$rt" = "$rs" ] && { printf 'OK'; return; }
    if [ -L "$t" ]; then
        [ "$(readlink "$t")" = "$s" ] && printf 'OK' || printf 'WRONG'
    elif [ -e "$t" ]; then
        printf 'CONFLICT'
    else
        printf 'MISSING'
    fi
}

_sl_repair() {
    local -a idx=("$@")
    [ "${#idx[@]}" -eq 0 ] && return 0
    local backup="$BACKUP_PREFIX-$(date +%s)" i t s rel
    mkdir -p "$backup"
    for i in "${idx[@]}"; do
        t="${MAN_TARGET[$i]}"; s="${MAN_SOURCE[$i]}"
        if [ ! -e "$s" ]; then warn "skip (source missing): ~${s#$HOME}"; continue; fi
        [ -L "$t" ] && rm "$t"
        if [ -e "$t" ]; then
            rel="${t#"$HOME"/}"
            mkdir -p "$backup/$(dirname "$rel")"
            mv "$t" "$backup/$rel"
            warn "backed up ~${t#$HOME} -> $backup/"
        fi
        mkdir -p "$(dirname "$t")"
        ln -s "$s" "$t"
        ok "~${t#$HOME} -> ~${s#$HOME}"
    done
}

_sl_remove_stale() {
    local st t
    while IFS= read -r t; do
        [ -L "$t" ] || continue
        st="$(readlink "$t")"
        case "$st" in
            "$SL_DIR"/*)
                [ -e "$t" ] && continue   # still valid
                rm "$t"
                warn "removed stale link ~${t#$HOME} -> ~${st#$HOME}"
                ;;
        esac
    done < <(_sl_stale)
}

validate_sym_links() {
    local mode="${1:-prompt}"
    _sl_build_manifest
    step "symlinks (.dotfiles)"
    info "repo = $SL_DIR"
    local i t s st bad=0 total=0 stale=0
    local -a bad_idx=()
    for i in "${!MAN_TARGET[@]}"; do
        t="${MAN_TARGET[$i]}"; s="${MAN_SOURCE[$i]}"
        total=$((total + 1))
        st="$(_sl_state "$t" "$s")"
        case "$st" in
            OK)       printf '  \033[32m\342\234\224\033[0m %s \033[2m-> %s\033[0m\n' "~${t#$HOME}" "~${s#$HOME}" ;;
            MISSING)  printf '  \033[33m\302\267\033[0m %s  \033[2m(missing -> %s)\033[0m\n' "~${t#$HOME}" "~${s#$HOME}"; bad=$((bad + 1)); bad_idx+=("$i") ;;
            WRONG)    printf '  \033[31m\342\234\230\033[0m %s  \033[2m(points to %s, expected %s)\033[0m\n' "~${t#$HOME}" "$(readlink "$t")" "~${s#$HOME}"; bad=$((bad + 1)); bad_idx+=("$i") ;;
            CONFLICT) printf '  \033[31m\342\234\230\033[0m %s  \033[2m(real file/dir in the way)\033[0m\n' "~${t#$HOME}"; bad=$((bad + 1)); bad_idx+=("$i") ;;
            BROKEN)   printf '  \033[31m\342\234\230\033[0m %s  \033[2m(source missing: %s)\033[0m\n' "~${t#$HOME}" "~${s#$HOME}"; bad=$((bad + 1)) ;;
        esac
    done
    while IFS= read -r t; do
        [ -L "$t" ] || continue
        case "$(readlink "$t")" in
            "$SL_DIR"/*) [ -e "$t" ] || { printf '  \033[33m\342\232\240\033[0m %s  \033[2m(stale -> %s)\033[0m\n' "~${t#$HOME}" "$(readlink "$t")"; stale=$((stale + 1)); } ;;
        esac
    done < <(_sl_stale)

    if [ "$bad" -eq 0 ] && [ "$stale" -eq 0 ]; then
        ok "all $total symlinks OK"
        return 0
    fi
    case "$mode" in
        check)
            fail "$bad to fix, $stale stale"
            return 1
            ;;
        fix)
            _sl_repair "${bad_idx[@]}"
            _sl_remove_stale
            return 0
            ;;
        *)
            if [ -t 0 ]; then
                printf '\n  Fix %d link(s) and remove %d stale? [y/N] ' "$bad" "$stale"
                read -r ans
                case "$ans" in
                    y|Y|yes|YES) _sl_repair "${bad_idx[@]}"; _sl_remove_stale; return 0 ;;
                esac
            else
                warn "not a terminal — re-run with --fix to repair"
            fi
            return 1
            ;;
    esac
}

ensure_sym_links() {
    _sl_build_manifest
    local i st
    local -a bad=()
    for i in "${!MAN_TARGET[@]}"; do
        st="$(_sl_state "${MAN_TARGET[$i]}" "${MAN_SOURCE[$i]}")"
        [ "$st" = OK ] || bad+=("$i")
    done
    if [ "${#bad[@]}" -eq 0 ]; then
        ok "dotfile symlinks already correct"
    else
        _sl_repair "${bad[@]}"
    fi
    _sl_remove_stale
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-validate}" in
        validate|"")   validate_sym_links prompt ;;
        --check|check) validate_sym_links check ;;
        --fix|fix)     validate_sym_links fix ;;
        -h|--help|help) _sl_usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; _sl_usage >&2; exit 2 ;;
    esac
fi
