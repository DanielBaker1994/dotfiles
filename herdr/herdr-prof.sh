#!/usr/bin/env bash
#
# herdr-prof — where does a slow herdr tab switch go?
#
# Every plugin handler run (agent-tabs, last, vim-nav) is logged by
# plugins/prof.sh, always on, so a "randomly slow" moment is already on
# record when you notice it:
#   herdr-prof [report] [MIN]  handler stats for the last MIN minutes (60):
#                              runs, p50/p95/max, lock wait, the slowest runs,
#                              and the most handlers that ran at once
#   herdr-prof tail            follow handler runs live
#   herdr-prof bench [N]       switch between this tab and the previous one N
#                              times (6) and time each switch until every
#                              handler it set off has finished
#   herdr-prof spawn           machine baseline: process spawn, herdr CLI round
#                              trip, jq, and one agent-tabs sync
#   herdr-prof trace on|off|report
#                              line-level timing of every handler run (set -x
#                              to $state/trace); report sums it per line
#   herdr-prof on|off|clear    logging on/off, empty the log
# The herdr server log (~/.config/herdr/herdr-server.log) has the matching
# tab.focus / api.request timestamps.

set -euo pipefail

state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-prof"
log="$state/handlers.log"
here="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
summary="$here/../bash/xtrace-summary.awk"
herdr="${HERDR_BIN_PATH:-herdr}"

ms_since() { echo $(((${EPOCHREALTIME/[.,]/} - ${1/[.,]/}) / 1000)); }
need_log() { [ -s "$log" ] || { echo "herdr-prof: no runs logged yet ($log)" >&2; exit 1; }; }

report() {
    local min="${1:-60}" since
    need_log
    [ -e "$state/off" ] && echo "(logging is OFF — herdr-prof on)"
    since=$((EPOCHSECONDS - min * 60))
    awk -F'\t' -v s="$since" '$1 >= s' "$log" >"$state/.window"
    [ -s "$state/.window" ] || { echo "no handler runs in the last $min min"; return; }

    printf 'handler runs, last %s min          runs    p50    p95    max  total   avg wait (ms)\n' "$min"
    # group key = script + args; sort by key then duration so percentiles are positional
    awk -F'\t' '{ printf "%s %s\t%d\t%d\n", $4, $5, $2, $3 }' "$state/.window" |
        sort -t$'\t' -k1,1 -k2,2n |
        awk -F'\t' '
            function flush() { if (n) printf "  %-32s %5d %6d %6d %6d %6d %6d\n", k, n, d[int((n+1)/2)], d[int(n*0.95+0.999)], d[n], tot, w/n }
            $1 != k { flush(); k = $1; n = 0; tot = 0; w = 0 }
            { d[++n] = $2; tot += $2; w += $3 }
            END { flush() }'

    printf '\nslowest runs\n'
    sort -t$'\t' -k2,2nr "$state/.window" | head -8 |
        while IFS=$'\t' read -r t ms wait script args; do
            printf '  %s  %6d ms  (waited %d)  %s %s\n' "$(date -r "${t%.*}" '+%H:%M:%S')" "$ms" "$wait" "$script" "$args"
        done

    # +1 at each start, -1 at each end: the peak is how many handlers overlapped
    local peak at
    read -r peak at < <(awk -F'\t' '{ printf "%.6f\t1\n%.6f\t-1\n", $1, $1 + $2 / 1000 }' "$state/.window" |
        sort -t$'\t' -k1,1n -k2,2n |
        awk -F'\t' '{ c += $2; if (c > peak) { peak = c; at = int($1) } } END { print peak + 0, at + 0 }')
    printf '\npeak overlap: %d handlers running at once (%s)\n' "$peak" "$(date -r "$at" '+%H:%M:%S')"
    printf '  >2 = events arrive faster than handlers finish; they queue (see avg wait)\n'
    rm -f "$state/.window"

    # keep the always-on log bounded
    if (($(wc -l <"$log") > 20000)); then
        tail -n 10000 "$log" >"$log.tmp" && mv -f "$log.tmp" "$log"
    fi
}

tail_log() {
    touch "$log"
    tail -n 0 -F "$log" | while IFS=$'\t' read -r t ms wait script args; do
        printf '%s  %6d ms  wait %4d  %s %s\n' "$(date -r "${t%.*}" '+%H:%M:%S')" "$ms" "$wait" "$script" "$args"
    done
}

# the log is written when a handler exits: quiet for 1s = everything settled
settle() {
    local size last t0=$EPOCHREALTIME
    last="$(wc -c <"$log" 2>/dev/null || echo 0)"
    while :; do
        sleep 0.25
        size="$(wc -c <"$log" 2>/dev/null || echo 0)"
        if [ "$size" = "$last" ] && (($(ms_since "$t0") > 1000)); then return; fi
        [ "$size" != "$last" ] && t0=$EPOCHREALTIME
        last="$size"
    done
}

bench() {
    local n="${1:-6}" tabs here_tab other ws i target t0 cli
    [ -e "$state/off" ] && { echo "herdr-prof: logging is off (herdr-prof on)" >&2; exit 1; }
    tabs="$("$herdr" tab list)"
    here_tab="${HERDR_TAB_ID:-$(jq -r '.result.tabs[] | select(.focused) | .tab_id' <<<"$tabs")}"
    ws="${here_tab%%:*}"
    other="$(jq -r --arg ws "$ws" --arg me "$here_tab" \
        '[.result.tabs[] | select(.workspace_id == $ws and .tab_id != $me)][0].tab_id // empty' <<<"$tabs")"
    [ -n "$other" ] || { echo "herdr-prof: bench needs a second tab in this workspace" >&2; exit 1; }
    printf 'switching %s <-> %s, %d times (each waits for its handlers to finish)\n' "$here_tab" "$other" "$n"
    printf '  #  focus cmd   handlers   busy until   handler ms (sum)\n'
    touch "$log"
    settle
    for ((i = 1; i <= n; i++)); do
        if ((i % 2)); then target="$other"; else target="$here_tab"; fi
        t0=$EPOCHREALTIME
        "$herdr" tab focus "$target" >/dev/null
        cli="$(ms_since "$t0")"
        settle
        # handlers started after t0: how many, and when the last one ended
        awk -F'\t' -v t0="${t0/,/.}" -v i="$i" -v cli="$cli" '
            $1 >= t0 { k++; sum += $2; e = ($1 - t0) * 1000 + $2; if (e > end) end = e }
            END { printf "%3d  %6d ms   %8d   %7d ms   %8d\n", i, cli, k, end, sum }' "$log"
    done
    "$herdr" tab focus "$here_tab" >/dev/null 2>&1 || true
    printf '\n"busy until" = ms from the switch until its last handler finished.\n'
    printf 'If it is high, see which handler: herdr-prof report 5\n'
}

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

spawn() {
    local panes
    # the plugin's own state dir, so `focus` finds its process cache
    export HERDR_PLUGIN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/local.agent-tabs"
    panes="$("$herdr" pane list | jq '.result.panes | "\(length) panes, \(map(select(.agent | not)) | length) without an agent"' -r)"
    printf '5 runs each                    min / median / max\n'
    printf 'process spawn (/usr/bin/true) %s   >5 ms = slow exec (endpoint security?)\n' "$(timeit 5 /usr/bin/true)"
    printf 'jq -n 1                       %s\n' "$(timeit 5 jq -n 1)"
    printf 'herdr pane list               %s   CLI + socket round trip\n' "$(timeit 5 "$herdr" pane list)"
    printf 'agent-tabs.sh focus           %s   once per tab switch / pane focus\n' \
        "$(timeit 5 bash "$here/plugins/agent-tabs/agent-tabs.sh" focus)"
    printf 'agent-tabs.sh sync            %s   (%s; on tab/pane create, close, move, agent status)\n' \
        "$(timeit 5 bash "$here/plugins/agent-tabs/agent-tabs.sh" sync)" "$panes"
}

case "${1:-report}" in
    report) shift || true; report "$@" ;;
    [0-9]*) report "$1" ;;
    tail) tail_log ;;
    bench) shift; bench "$@" ;;
    spawn) spawn ;;
    trace)
        # flag file $state/trace; plugins/prof.sh writes one file per run to traces/
        case "${2:-report}" in
            on) mkdir -p "$state/traces"; : >"$state/trace"; echo "tracing every handler run into $state/traces (herdr-prof trace off)" ;;
            off) rm -f "$state/trace"; echo "tracing off" ;;
            report)
                shopt -s nullglob
                files=("$state"/traces/*.xtrace)
                ((${#files[@]})) || { echo "herdr-prof: no traces (herdr-prof trace on, then use herdr)" >&2; exit 1; }
                printf '%d traced runs; slowest lines summed over all of them\n' "${#files[@]}"
                awk -v mode=lines -f "$summary" "${files[@]}" | sort -t$'\t' -k1,1nr | head -20 |
                    awk -F'\t' '{ printf "%8.1f ms x%-5d %-34s %s\n", $1, $2, $3, $4 }'
                ;;
            clear) rm -rf "$state/traces"; echo "traces removed" ;;
            *) echo "usage: herdr-prof trace on|off|report|clear" >&2; exit 2 ;;
        esac
        ;;
    on) rm -f "$state/off"; echo "handler logging on" ;;
    off) mkdir -p "$state"; : >"$state/off"; echo "handler logging off" ;;
    clear) : >"$log"; echo "log cleared" ;;
    -h | --help | help) sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) echo "usage: herdr-prof [report [MIN] | tail | bench [N] | spawn | trace on|off|report | on | off | clear]" >&2; exit 2 ;;
esac
