#!/usr/bin/env bash
# Dedicated workflow commands.
# Sourced from ~/.bashrc — drop reusable day-to-day shell helpers here.

# ff <name> — print a shell function's definition, then a `vim +N file`
# command that jumps straight to where it is defined.
ff() {
    local fn="${1-}"
    if [[ -z "$fn" ]]; then
        echo "usage: ff <function-name>" >&2
        return 1
    fi
    if ! declare -f "$fn" >/dev/null 2>&1; then
        echo "ff: '$fn' is not a shell function" >&2
        return 1
    fi

    # declare -F only reports the definition file/line when extdebug is on.
    local _ line file had_extdebug=0
    shopt -q extdebug && had_extdebug=1
    shopt -s extdebug
    read -r _ line file < <(declare -F "$fn")
    ((had_extdebug)) || shopt -u extdebug

    # bat for highlighted output when available (aliases don't expand inside
    # functions, and --no-pager keeps it inline); plain declare -f otherwise.
    if command -v bat >/dev/null 2>&1; then
        declare -f "$fn" | bat --no-pager --language bash --style=plain
    else
        declare -f "$fn"
    fi
    echo
    if [[ -n "${file:-}" && -n "${line:-}" ]]; then
        echo "vim +$line $file"
    else
        echo "# definition location not found (interactive/eval'd function?)"
    fi
}
