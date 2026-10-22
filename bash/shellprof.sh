#!/usr/bin/env bash
#
# shellprof — why is a new shell slow?
#
#   shellprof [trace] [N]  start one login shell with every line of
#                          .bash_profile/.bashrc (and what they source,
#                          ~/external/* included) timestamped; print the
#                          per-file totals and the N slowest lines (default 15)
#   shellprof bench [N]    N timed startups (default 10) next to a bare bash
#                          and a bare process spawn, so the cost of your config
#                          is split from the cost of the machine
#   shellprof prompt [DIR] per-module prompt cost in DIR (starship timings)
#
# Tracing works through the BASHPROF hook at the top/bottom of .bash_profile.
# It needs bash 5+ (EPOCHREALTIME); set SHELLPROF_BASH to pick another bash.
# Traces stay in $TMPDIR/shellprof.* for a second look:
#   awk -v mode=lines -f ~/.dotfiles/bash/xtrace-summary.awk FILE | sort -t$'\t' -k1,1nr

set -euo pipefail
# shellcheck disable=SC2016 # $vars below are expanded by the child bash

here="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
summary="$here/xtrace-summary.awk"
sh="${SHELLPROF_BASH:-$(command -v bash)}"

ms_since() { echo $(((${EPOCHREALTIME/[.,]/} - ${1/[.,]/}) / 1000)); }

check_bash() {
    local v
    v="$("$sh" -c 'echo "${BASH_VERSINFO[0]}"')"
    if ((v < 5)); then
        echo "shellprof: $sh is bash $v; tracing needs bash 5+ (brew install bash, or SHELLPROF_BASH=...)" >&2
        exit 1
    fi
}

trace() {
    local top="${1:-15}" out err t0 wall
    check_bash
    out="$(mktemp "${TMPDIR:-/tmp}/shellprof.XXXXXX")"
    err="$out.stderr"
    t0=$EPOCHREALTIME
    BASHPROF="$out" "$sh" -lic exit </dev/null >/dev/null 2>"$err" || true
    wall="$(ms_since "$t0")"

    printf '\n%s (%s)\n' "$("$sh" -c 'echo "bash $BASH_VERSION"')" "$sh"
    printf 'login shell: %s ms wall, %s ms traced (tracing itself adds some)\n' \
        "$wall" "$(awk -v mode=total -f "$summary" "$out" | cut -f1)"

    printf '\nby file\n'
    awk -v mode=files -f "$summary" "$out" | sort -t$'\t' -k1,1nr |
        awk -F'\t' '{ printf "%8.1f ms  %s\n", $1, $2 }'

    printf '\nslowest lines\n'
    awk -v mode=lines -f "$summary" "$out" | sort -t$'\t' -k1,1nr | head -n "$top" |
        awk -F'\t' '{ loc = $3; sub(/^.*\//, "", loc)
                      printf "%8.1f ms %s %-34s %s\n", $1, ($2 > 1 ? sprintf("x%-3d", $2) : "    "), loc, $4 }'

    # bash -i without a terminal always complains about job control
    grep -vE 'cannot set terminal process group|no job control in this shell|^logout$' "$err" >"$err.tmp" || true
    mv -f "$err.tmp" "$err"
    if [ -s "$err" ]; then
        printf '\nstartup stderr (%s lines, first 5):\n' "$(wc -l <"$err" | tr -d ' ')"
        head -5 "$err" | sed 's/^/  /'
    fi
    printf '\ntrace: %s\n' "$out"
}

# N runs of CMD... -> "min / median / max ms"
timeit() {
    local n="$1" i t0 times=()
    shift
    for ((i = 0; i < n; i++)); do
        t0=$EPOCHREALTIME
        "$@" </dev/null >/dev/null 2>&1 || true
        times+=("$(ms_since "$t0")")
    done
    printf '%s\n' "${times[@]}" | sort -n |
        awk '{ a[NR] = $1 } END { printf "%5d / %5d / %5d ms", a[1], a[int((NR + 1) / 2)], a[NR] }'
}

bench() {
    local n="${1:-10}"
    check_bash
    if command -v hyperfine >/dev/null; then
        hyperfine -N --warmup 2 --runs "$n" "$sh -lic exit" "$sh --noprofile --norc -ic exit" /usr/bin/true
        return
    fi
    printf '%d runs each             min / median / max\n' "$n"
    printf 'process spawn  %s   (/usr/bin/true: >5 ms = slow machine, e.g. endpoint security)\n' "$(timeit "$n" /usr/bin/true)"
    printf 'bare bash      %s\n' "$(timeit "$n" "$sh" --noprofile --norc -ic exit)"
    printf 'your config    %s   (-> shellprof trace)\n' "$(timeit "$n" "$sh" -lic exit)"
}

prompt() {
    local dir="${1:-$PWD}"
    command -v starship >/dev/null || { echo "shellprof: no starship on PATH" >&2; exit 1; }
    cd "$dir"
    printf 'starship prompt in %s: %s\n\n' "$dir" "$(timeit 5 starship prompt)"
    starship timings
}

case "${1:-trace}" in
    trace) shift || true; trace "$@" ;;
    bench) shift; bench "$@" ;;
    prompt) shift; prompt "$@" ;;
    [0-9]*) trace "$1" ;;
    -h | --help | help) sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) echo "usage: shellprof [trace [N] | bench [N] | prompt [DIR]]" >&2; exit 2 ;;
esac
