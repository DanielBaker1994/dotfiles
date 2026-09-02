#!/usr/bin/env bash
# shellcheck disable=SC2016
# =============================================================================
# logstats.sh — Universal, Team-Agnostic Log File Intelligence & Diagnostics
# =============================================================================
#
# Provides standalone CLI execution and sourceable bash functions:
#   logstats, logfilestats, loggaps, logbursts, logerrors, logrepeats,
#   logtimeline, logaround, loglatency, logsniff, logslice, logstage, logreport
#
# Supported Diagnostic Modes:
#   summary   (default) Comprehensive overview: duration, rates, gaps, errors, templates
#   report    Full multi-pass diagnostic suite (summary, gaps, bursts, errors, repeats, timeline)
#   gaps      Longest silences, freezes, and pauses between log lines
#   bursts    Peak log-rate intervals, runaway loops, and message floods
#   errors    Error level breakdown, first error root-cause anchor, top error patterns
#   repeats   Structural template frequencies; use --rare for 1-off anomalies
#   timeline  ASCII activity and error histogram across time buckets
#   around    Time-based context window (±N seconds) around pattern matches
#   latency   Percentiles (min, p50, p90, p95, p99, max) of numbers in matching lines
#   sniff     Format inspector: deep-scans timestamps, prefixes, and sample masks
#   slice     Fast streaming filter with rule evaluation
#   stage     Production orchestrator: copies log to staging dir, unpacks, runs, and cleans up
#
# Supported Timestamp Formats (Auto-detected with deep scanning):
#   iso          2026-08-23T14:01:02.123 / 2026-08-23 14:01:02,123 (dot or comma, tz ok)
#   bracketed    [2026-08-23 14:01:02.123] (spdlog, log4j, glog)
#   slash        2026/08/23 14:01:02 (IIS/Windows style)
#   clf          23/Aug/2026:14:01:02 (Apache/Nginx access log)
#   apache       [Sun Aug 23 14:01:02 2026] (Apache error log)
#   syslog       Aug 23 14:01:02 / Aug 23 2026 14:01:02
#   hdfs         081109 203615 (Hadoop compact format)
#   epoch        1724418062 (sec) or 1724418062123 (ms) / 1724418062.123
#   time_only    14:01:02.123 (assumes current date)
#
# Portability:
#   Compatible with Bash 3.2+ (macOS stock) and Bash 4/5+ (Linux).
#   Pure POSIX AWK implementation — runs on macOS BSD awk and Linux GNU gawk.
#   LC_ALL=C byte-mode parsing survives binary garbage in logs.
#   Compression: auto-decompresses .gz, .bz2, .xz, .zst or reads from stdin.
# =============================================================================

# ---------------------------------------------------------------------------
# Tool auto-detection for maximum performance (mawk/gawk, pigz)
# ---------------------------------------------------------------------------
_ls_detect_tools() {
    _LS_AWK="awk"
    if command -v mawk >/dev/null 2>&1; then
        _LS_AWK="mawk"
    elif command -v gawk >/dev/null 2>&1; then
        _LS_AWK="gawk"
    fi

    _LS_GZIP="gzip"
    if command -v pigz >/dev/null 2>&1; then
        _LS_GZIP="pigz"
    fi
}
_ls_detect_tools

# ---------------------------------------------------------------------------
# Preflight environment check & portable tempfile creation
# ---------------------------------------------------------------------------
_ls_check_env() {
    _ls_detect_tools
    local missing=()
    for cmd in "$_LS_AWK" grep sort uniq wc cat cp df "$_LS_GZIP"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "logstats: required utility missing: ${missing[*]}" >&2
        return 1
    fi
    return 0
}

_ls_mktemp() {
    mktemp "${TMPDIR:-/tmp}/logstats.XXXXXX" 2>/dev/null || \
    mktemp -t logstats 2>/dev/null || {
        echo "logstats: failed to create temporary file" >&2
        return 1
    }
}

_ls_prepare_input() {
    local target="$1"
    if [[ "$target" == "-" || -z "$target" ]]; then
        local tmp_in
        tmp_in=$(_ls_mktemp) || return 1
        cat > "$tmp_in"
        echo "$tmp_in"
    else
        echo "$target"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Stream reader: dispatch on compression extension or read stdin
# ---------------------------------------------------------------------------
_lgz_cat() {
    local target="${1:--}"
    if [[ "$target" == "-" || -z "$target" ]]; then
        cat
        return
    fi
    if [[ ! -r "$target" ]]; then
        echo "logstats: cannot read file '$target'" >&2
        return 1
    fi
    case "$target" in
        *.gz|*.Z)
            "$_LS_GZIP" -dc -- "$target" ;;
        *.bz2)
            command -v bzip2 >/dev/null 2>&1 || { echo "logstats: bzip2 missing" >&2; return 1; }
            bzip2 -dc -- "$target" ;;
        *.xz)
            command -v xz >/dev/null 2>&1 || { echo "logstats: xz missing" >&2; return 1; }
            xz -dc -- "$target" ;;
        *.zst|*.zstd)
            command -v zstd >/dev/null 2>&1 || { echo "logstats: zstd missing" >&2; return 1; }
            zstd -dc -- "$target" ;;
        *)
            cat -- "$target" ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared AWK Library (Interpolated in AWK scripts)
# ---------------------------------------------------------------------------
_LS_LIB='
function mon_init(    i, n, mn) {
    n = split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= n; i++) MON[mn[i]] = i
}
function d2e(y, m, d, H, M, S,    era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + H * 3600 + M * 60 + S
}
function e2dt(e, tzo,    z, era, doe, yoe, y, doy, mp, dd, mm, rem, hh, mi, ss) {
    e += (tzo + 0)
    z = int(e / 86400) + 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    dd = doy - int((153 * mp + 2) / 5) + 1
    mm = mp + (mp < 10 ? 3 : -9)
    y += (mm <= 2)
    rem = e - int(e / 86400) * 86400
    if (rem < 0) rem += 86400
    hh = int(rem / 3600); mi = int((rem % 3600) / 60); ss = int(rem % 60)
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, mm, dd, hh, mi, ss)
}
function hum(s) {
    if (s >= 3600) return sprintf("%dh%02dm", int(s / 3600), int(s % 3600 / 60))
    if (s >= 60)   return sprintf("%dm%02ds", int(s / 60), int(s % 60))
    return sprintf("%.3fs", s)
}
function hms(s,    h, m) {
    h = int(s / 3600)
    m = int(s % 3600 / 60)
    return sprintf("%dh %dm %.3fs", h, m, s - h * 3600 - m * 60)
}
function log_level(line,    up) {
    up = toupper(line)
    if (match(up, /(^|[^A-Z])(FATAL|CRITICAL|PANIC|EMERGENCY|SEVERE)([^A-Z]|$)/)) return "FATAL"
    if (match(up, /(^|[^A-Z])(ERROR|ERR)([^A-Z]|$)/)) return "ERROR"
    if (match(up, /(^|[^A-Z])(WARN|WARNING)([^A-Z]|$)/)) return "WARN"
    if (match(up, /(^|[^A-Z])(INFO|NOTICE)([^A-Z]|$)/)) return "INFO"
    if (match(up, /(^|[^A-Z])(DEBUG|DBG)([^A-Z]|$)/)) return "DEBUG"
    if (match(up, /(^|[^A-Z])(TRACE)([^A-Z]|$)/)) return "TRACE"
    return "OTHER"
}
function skel(x, head_toks,    n, w, i, res, word, prefix, suffix, limit) {
    # 1. Mask JSON/XML string values while preserving property/attribute names
    gsub(/:[ \t]*"[^"]*"/, ": \"*\"", x)
    gsub(/:[ \t]*\x27[^\x27]*\x27/, ": \x27*\x27", x)
    gsub(/=[ \t]*"[^"]*"/, "=\"*\"", x)
    gsub(/=[ \t]*\x27[^\x27]*\x27/, "=\x27*\x27", x)

    # 2. Standalone quotes followed by common delimiters
    gsub(/"[^":]+"[ \t,;\]\)\}]/, "\"*\" ", x)
    gsub(/"[^":]+"$/, "\"*\"", x)
    gsub(/\x27[^:\x27]+\x27[ \t,;\]\)\}]/, "\x27*\x27 ", x)
    gsub(/\x27[^:\x27]+\x27$/, "\x27*\x27", x)

    # 3. XML / HTML text node content between > and <
    gsub(/>([^<]+)</, ">*<", x)

    # 4. URLs & URIs
    gsub(/https?:\/\/[^ \t"'\''<>]+/, "<URL>", x)

    # 5. UUIDs / GUIDs
    gsub(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, "<UUID>", x)

    # 6. Hex pointers and memory addresses
    gsub(/0[xX][0-9a-fA-F]+/, "<HEX>", x)

    # 7. IPv4 addresses (with optional port) and IPv6
    gsub(/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(:[0-9]+)?/, "<IP>", x)
    gsub(/[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){5,7}/, "<IP>", x)

    # 8. Unquoted Key-Value values: e.g. status=OK, count=42 -> status=*
    gsub(/=[^ \t,;"\x27<>]+/, "=* ", x)

    # 9. File paths with optional line numbers: /path/to/file.cpp:123
    gsub(/(\/[A-Za-z0-9_.-]+){2,}(:[0-9]+)?/, "<PATH>", x)

    # 10. Split words for high-entropy alphanumeric token reduction & head clamping
    n = split(x, w, /[ \t]+/)
    res = ""
    limit = (head_toks > 0 && head_toks < n ? head_toks : n)
    for (i = 1; i <= limit; i++) {
        word = w[i]
        prefix = ""; suffix = ""
        if (match(word, /^[^A-Za-z0-9]+/)) {
            prefix = substr(word, RSTART, RLENGTH)
            word = substr(word, RLENGTH + 1)
        }
        if (match(word, /[^A-Za-z0-9]+$/)) {
            suffix = substr(word, RSTART, RLENGTH)
            word = substr(word, 1, length(word) - RLENGTH)
        }

        if (word != "" && word !~ /^<.*>$/) {
            # Long hash / token (12+ alphanumeric characters)
            if (length(word) >= 12 && word ~ /^[A-Za-z0-9_-]+$/) {
                word = "<TOKEN>"
            }
            # Mixed alphanumeric identifiers (e.g. user_200, ord992b, txn_8821c, req-123)
            else if (word ~ /[A-Za-z]/ && word ~ /[0-9]/ && word ~ /^[A-Za-z0-9_.-]+$/) {
                word = "<ID>"
            }
            # Pure numbers / floats
            else if (word ~ /^[0-9]+(\.[0-9]+)?$/) {
                word = "N"
            }
        }
        res = (res == "" ? "" : res " ") prefix word suffix
    }
    if (head_toks > 0 && head_toks < n) res = res " ..."
    return res
}
function ts_parse(line,    ts, frac, a, t2, tok, L, w, y, d) {
    if (fmt == "epoch") {
        if (!match(line, /^[0-9]+(\.[0-9]+)?/)) return 0
        tok = substr(line, RSTART, RLENGTH)
        L = length(tok)
        G_E = tok + 0
        if (L >= 13 && index(tok, ".") == 0) G_E = G_E / 1000
        G_SHOW = tok
        G_S = RSTART; G_L = RLENGTH
        return 1
    }
    if (fmt == "iso") {
        if (!match(line, /\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?\]?/)) return 0
    } else if (fmt == "slash") {
        if (!match(line, /\[?[0-9]{4}\/[0-9]{2}\/[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?\]?/)) return 0
    } else if (fmt == "clf") {
        if (!match(line, /\[?[0-9]{2}\/[A-Z][a-z]{2}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return 0
    } else if (fmt == "apache") {
        if (!match(line, /\[[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}(.[0-9]+)? [0-9]{4}\]/)) return 0
    } else if (fmt == "syslog") {
        if (!match(line, /^[A-Z][a-z]{2} +[0-9]{1,2} ([0-9]{4} )?[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return 0
    } else if (fmt == "hdfs") {
        if (!match(line, /^[0-9]{6} [0-9]{6}/)) return 0
    } else if (fmt == "time_only") {
        if (!match(line, /^\[?[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?\]?/)) return 0
    } else return 0

    ts = substr(line, RSTART, RLENGTH)
    G_S = RSTART; G_L = RLENGTH
    G_SHOW = ts
    frac = 0

    if (fmt == "iso" || fmt == "slash") {
        gsub(/[\[\]]/, "", ts)
        sub(/T/, " ", ts)
        G_SHOW = ts
        if (match(ts, /[.,][0-9]+$/)) {
            frac = ("0." substr(ts, RSTART + 1, RLENGTH - 1)) + 0
            ts = substr(ts, 1, RSTART - 1)
        }
        split(ts, a, /[-\/ :]/)
        G_E = d2e(a[1] + 0, a[2] + 0, a[3] + 0, a[4] + 0, a[5] + 0, a[6] + 0) + frac
    } else if (fmt == "clf") {
        gsub(/[\[\]]/, "", ts)
        split(ts, a, /[\/:]/)
        if (!(a[2] in MON)) return 0
        G_E = d2e(a[3] + 0, MON[a[2]], a[1] + 0, a[4] + 0, a[5] + 0, a[6] + 0)
    } else if (fmt == "apache") {
        gsub(/[\[\]]/, "", ts)
        gsub(/ +/, " ", ts)
        split(ts, a, " ")
        if (!(a[2] in MON)) return 0
        split(a[4], t2, ":")
        if (match(t2[3], /\.[0-9]+$/)) {
            frac = ("0" substr(t2[3], RSTART, RLENGTH)) + 0
            t2[3] = substr(t2[3], 1, RSTART - 1)
        }
        G_E = d2e(a[5] + 0, MON[a[2]], a[3] + 0, t2[1] + 0, t2[2] + 0, t2[3] + 0) + frac
    } else if (fmt == "syslog") {
        gsub(/ +/, " ", ts)
        split(ts, a, " ")
        if (!(a[1] in MON)) return 0
        if (length(a[2]) == 4) {
            y = a[2] + 0; d = a[3] + 0; split(a[4], t2, ":")
        } else {
            y = yr + 0; d = a[2] + 0; split(a[3], t2, ":")
        }
        G_E = d2e(y, MON[a[1]], d, t2[1] + 0, t2[2] + 0, t2[3] + 0)
    } else if (fmt == "hdfs") {
        split(ts, a, " ")
        G_E = d2e(2000 + substr(a[1], 1, 2), substr(a[1], 3, 2) + 0, substr(a[1], 5, 2) + 0, \
                  substr(a[2], 1, 2) + 0, substr(a[2], 3, 2) + 0, substr(a[2], 5, 2) + 0)
    } else if (fmt == "time_only") {
        gsub(/[\[\]]/, "", ts)
        if (match(ts, /\.[0-9]+$/)) {
            frac = ("0" substr(ts, RSTART, RLENGTH)) + 0
            ts = substr(ts, 1, RSTART - 1)
        }
        split(ts, a, ":")
        G_E = d2e(yr + 0, cur_m + 0, cur_d + 0, a[1] + 0, a[2] + 0, a[3] + 0) + frac
    }
    return 1
}
'

# ---------------------------------------------------------------------------
# Deep Format Sniffer: scans up to 2000 lines to bypass startup banners
# ---------------------------------------------------------------------------
_ls_sniff() {
    _lgz_cat "$1" 2>/dev/null | head -n 2000 | LC_ALL=C "$_LS_AWK" '
        {
            if (match($0, /\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?/)) iso++
            else if (match($0, /\[?[0-9]{4}\/[0-9]{2}\/[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?/)) slash++
            else if (match($0, /\[?[0-9]{2}\/[A-Z][a-z]{2}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/)) clf++
            else if (match($0, /\[[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}(.[0-9]+)? [0-9]{4}\]/)) apache++
            else if (match($0, /^[A-Z][a-z]{2} +[0-9]{1,2} ([0-9]{4} )?[0-9]{2}:[0-9]{2}:[0-9]{2}/)) syslog++
            else if (match($0, /^[0-9]{6} [0-9]{6}/)) hdfs++
            else if (match($0, /^[0-9]{10,13}(\.[0-9]+)?([ \t]|$)/)) epoch++
            else if (match($0, /^\[?[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?\]?[ \t]/)) time_only++
        }
        END {
            best = "none"; bc = 0
            if (iso > bc)       { bc = iso;       best = "iso" }
            if (slash > bc)     { bc = slash;     best = "slash" }
            if (clf > bc)       { bc = clf;       best = "clf" }
            if (apache > bc)    { bc = apache;    best = "apache" }
            if (syslog > bc)    { bc = syslog;    best = "syslog" }
            if (hdfs > bc)      { bc = hdfs;      best = "hdfs" }
            if (epoch > bc)     { bc = epoch;     best = "epoch" }
            if (time_only > bc) { bc = time_only; best = "time_only" }
            if (bc < 3) best = "none"
            print best
        }'
}

# ---------------------------------------------------------------------------
# Options parser helper (shared across modes)
# ---------------------------------------------------------------------------
_ls_parse_filter_args() {
    OPT_FILE=""
    OPT_RANGE="1:-1"
    OPT_TOPN="10"
    OPT_MINGAP="1.0"
    OPT_SECS="5"
    OPT_UNIT="m"
    OPT_FMT=""
    OPT_RARE=0
    OPT_REQUIRE_TS=0
    OPT_HEAD_TOKS=0
    OPT_SKIP_UNTIL=""
    OPT_SKIP_WHILE=""
    OPT_WORKDIR=""
    OPT_KEEP=0
    OPT_REPORT=0
    OPT_FORCE=0
    OPT_QUIET=0
    OPT_IGNORE_PATS=()
    OPT_FILTER_PATS=()
    OPT_EXTRA_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [[ -z "$OPT_FILE" ]]; then OPT_FILE="$1"; else OPT_EXTRA_ARGS+=("$1"); fi
                    shift
                done
                break ;;
            -)
                if [[ -z "$OPT_FILE" ]]; then OPT_FILE="-"; else OPT_EXTRA_ARGS+=("-"); fi
                shift ;;
            --range)
                OPT_RANGE="$2"; shift 2 ;;
            -n|--top)
                OPT_TOPN="$2"; shift 2 ;;
            -H|--head-tokens)
                OPT_HEAD_TOKS="$2"; shift 2 ;;
            --min-gap)
                local mg="$2"
                mg="${mg%s}"
                OPT_MINGAP="$mg"; shift 2 ;;
            --secs)
                OPT_SECS="$2"; shift 2 ;;
            --unit)
                OPT_UNIT="$2"; shift 2 ;;
            --format)
                OPT_FMT="$2"; shift 2 ;;
            --rare|--outliers)
                OPT_RARE=1; shift ;;
            --require-ts|--ignore-nonts)
                OPT_REQUIRE_TS=1; shift ;;
            -s|--skip-until)
                OPT_SKIP_UNTIL="$2"; shift 2 ;;
            --skip-while)
                OPT_SKIP_WHILE="$2"; shift 2 ;;
            -I|--ignore)
                OPT_IGNORE_PATS+=("$2"); shift 2 ;;
            -F|--filter)
                OPT_FILTER_PATS+=("$2"); shift 2 ;;
            -W|--workdir)
                OPT_WORKDIR="$2"; shift 2 ;;
            --keep|--keep-staged|--no-cleanup)
                OPT_KEEP=1; shift ;;
            --report|--all)
                OPT_REPORT=1; shift ;;
            --force)
                OPT_FORCE=1; shift ;;
            -q|--quiet)
                OPT_QUIET=1; shift ;;
            -h|--help)
                return 10 ;;
            -*)
                echo "logstats: unknown option '$1'" >&2; return 1 ;;
            *)
                if [[ -z "$OPT_FILE" ]]; then
                    OPT_FILE="$1"
                else
                    OPT_EXTRA_ARGS+=("$1")
                fi
                shift ;;
        esac
    done

    if [[ -z "$OPT_FILE" ]]; then
        OPT_FILE="-"
    fi
    return 0
}

_ls_resolve_range() {
    local range="$1" file="$2"
    local start end
    if [[ "$range" =~ ^(-?[0-9]*):(-?[0-9]*)$ ]]; then
        start="${BASH_REMATCH[1]:-1}"
        end="${BASH_REMATCH[2]:--1}"
    else
        echo "logstats: bad RANGE '$range' (want e.g. 100:-1, 100:, :500)" >&2
        return 1
    fi
    if ((start == 0 || end == 0)); then
        echo "logstats: RANGE is 1-based; 0 is not a valid line number" >&2
        return 1
    fi
    if [[ "$file" == "-" ]]; then
        if ((start < 0 || (end < 0 && end != -1) )); then
            echo "logstats: negative line offsets from end-of-stream not supported on stdin" >&2
            return 1
        fi
        ((start < 1)) && start=1
        ((end == -1)) && end=0
        echo "$start $end"
        return 0
    fi
    if ((start < 0 || end < 0)); then
        local total
        total=$(_lgz_cat "$file" | wc -l)
        ((start < 0)) && start=$((total + start + 1))
        ((end < 0)) && end=$((total + end + 1))
    fi
    ((start < 1)) && start=1
    if ((end > 0 && end < start)); then
        echo "logstats: RANGE resolves to an empty window ($start..$end)" >&2
        return 1
    fi
    echo "$start $end"
}

# =============================================================================
# MODE: STAGE (Production Safe Copy -> Unpack -> Run -> Auto-Cleanup)
# =============================================================================
logstage() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 || -z "$OPT_FILE" || "$OPT_FILE" == "-" ]]; then
        cat <<'EOF'
usage: logstats stage FILE [MODE] [OPTIONS]
  Production orchestrator: Safely copies a log or compressed archive (.gz/.bz2/.xz/.zst)
  to a user-owned staging directory, decompresses it locally for fast multi-pass analysis,
  runs the requested diagnostic mode (or full --report), and automatically cleans up on exit.

Options:
  -W, --workdir <DIR>   Staging directory base (default: $TMPDIR or /tmp)
  --keep, --no-cleanup  Keep staged unpacked file on exit (retains local copy)
  --report, --all       Run full multi-pass diagnostic report
  --force               Bypass disk space headroom check
  -q, --quiet           Suppress staging progress notifications
  [MODE]                Diagnostic mode to run: summary (default), gaps, bursts,
                        errors, repeats, timeline, around, latency, sniff, slice

Examples:
  logstats stage /var/log/app/app.log.gz --report
  logstats stage /var/log/app/app.log.gz gaps --min-gap 5s
  logstats stage -W /dev/shm /var/log/app/app.log.gz summary -s "Server ready"
EOF
        [[ $rc -eq 10 ]] && return 0
        return 1
    fi

    local src_file="$OPT_FILE"
    if [[ ! -r "$src_file" ]]; then
        echo "logstats stage: cannot read source file '$src_file'" >&2
        return 1
    fi

    local base_workdir="${OPT_WORKDIR:-${TMPDIR:-/tmp}}"
    if [[ ! -d "$base_workdir" || ! -w "$base_workdir" ]]; then
        echo "logstats stage: staging base directory '$base_workdir' does not exist or is not writable" >&2
        return 1
    fi

    # Create dedicated staging folder
    local stage_dir
    stage_dir=$(mktemp -d "${base_workdir}/logstage_XXXXXX" 2>/dev/null) || {
        echo "logstats stage: failed to create staging directory in '$base_workdir'" >&2
        return 1
    }

    # Setup trap to guarantee cleanup
    local keep="$OPT_KEEP" quiet="$OPT_QUIET"
    _ls_stage_cleanup() {
        if [[ "$keep" -eq 0 && -d "$stage_dir" ]]; then
            [[ "$quiet" -eq 0 ]] && echo "logstats stage: cleaning up staging directory $stage_dir" >&2
            rm -rf "$stage_dir"
        fi
    }
    trap _ls_stage_cleanup EXIT INT TERM HUP

    # Preflight disk space check
    if [[ "$OPT_FORCE" -eq 0 ]]; then
        local src_size_kb avail_kb
        src_size_kb=$(wc -c < "$src_file" 2>/dev/null | awk '{print int($1/1024)}')
        avail_kb=$(df -k "$stage_dir" 2>/dev/null | tail -n 1 | awk '{print $4}')
        local est_needed_kb=$(( (src_size_kb * 10) + 51200 )) # 10x ratio + 50MB buffer

        if [[ -n "$avail_kb" && "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb < est_needed_kb )); then
            echo "logstats stage: WARNING - low disk space in '$base_workdir'" >&2
            echo "  Available: $((avail_kb / 1024))MB | Estimated needed for unpack: $((est_needed_kb / 1024))MB" >&2
            echo "  Use --force to proceed anyway or --workdir <DIR> to specify a different mount." >&2
            return 1
        fi
    fi

    local filename
    filename=$(basename "$src_file")
    local staged_copy="$stage_dir/$filename"

    [[ "$quiet" -eq 0 ]] && echo "logstats stage: copying '$src_file' -> '$staged_copy' ..." >&2
    cp -- "$src_file" "$staged_copy" || {
        echo "logstats stage: failed to copy file to staging directory" >&2
        return 1
    }

    local target_unpacked="$staged_copy"
    case "$filename" in
        *.gz|*.Z)
            [[ "$quiet" -eq 0 ]] && echo "logstats stage: decompressing gzip archive ..." >&2
            if command -v pigz >/dev/null 2>&1; then
                pigz -d "$staged_copy" || gzip -d "$staged_copy"
            else
                gzip -d "$staged_copy"
            fi
            target_unpacked="${staged_copy%.*}" ;;
        *.bz2)
            [[ "$quiet" -eq 0 ]] && echo "logstats stage: decompressing bzip2 archive ..." >&2
            bzip2 -d "$staged_copy"
            target_unpacked="${staged_copy%.bz2}" ;;
        *.xz)
            [[ "$quiet" -eq 0 ]] && echo "logstats stage: decompressing xz archive ..." >&2
            xz -d "$staged_copy"
            target_unpacked="${staged_copy%.xz}" ;;
        *.zst|*.zstd)
            [[ "$quiet" -eq 0 ]] && echo "logstats stage: decompressing zstd archive ..." >&2
            zstd -d --rm "$staged_copy"
            target_unpacked="${staged_copy%.*}" ;;
    esac

    if [[ ! -r "$target_unpacked" ]]; then
        echo "logstats stage: decompression failed or unpacked file unreadable" >&2
        return 1
    fi

    # Determine what mode to run
    local run_mode="summary"
    if [[ "$OPT_REPORT" -eq 1 ]]; then
        run_mode="report"
    elif [[ ${#OPT_EXTRA_ARGS[@]} -gt 0 ]]; then
        case "${OPT_EXTRA_ARGS[0]}" in
            summary|report|gaps|bursts|errors|repeats|timeline|around|latency|sniff|slice)
                run_mode="${OPT_EXTRA_ARGS[0]}"
                OPT_EXTRA_ARGS=("${OPT_EXTRA_ARGS[@]:1}") ;;
        esac
    fi

    # Re-construct arguments for diagnostic run
    local diag_args=()
    [[ -n "$OPT_RANGE" && "$OPT_RANGE" != "1:-1" ]] && diag_args+=(--range "$OPT_RANGE")
    [[ -n "$OPT_TOPN" && "$OPT_TOPN" != "10" ]] && diag_args+=(--top "$OPT_TOPN")
    [[ -n "$OPT_MINGAP" && "$OPT_MINGAP" != "1.0" ]] && diag_args+=(--min-gap "$OPT_MINGAP")
    [[ -n "$OPT_SECS" && "$OPT_SECS" != "5" ]] && diag_args+=(--secs "$OPT_SECS")
    [[ -n "$OPT_UNIT" && "$OPT_UNIT" != "m" ]] && diag_args+=(--unit "$OPT_UNIT")
    [[ -n "$OPT_FMT" ]] && diag_args+=(--format "$OPT_FMT")
    [[ "$OPT_HEAD_TOKS" -gt 0 ]] && diag_args+=(--head-tokens "$OPT_HEAD_TOKS")
    [[ "$OPT_RARE" -eq 1 ]] && diag_args+=(--rare)
    [[ "$OPT_REQUIRE_TS" -eq 1 ]] && diag_args+=(--require-ts)
    [[ -n "$OPT_SKIP_UNTIL" ]] && diag_args+=(--skip-until "$OPT_SKIP_UNTIL")
    [[ -n "$OPT_SKIP_WHILE" ]] && diag_args+=(--skip-while "$OPT_SKIP_WHILE")
    for pat in "${OPT_IGNORE_PATS[@]}"; do diag_args+=(-I "$pat"); done
    for pat in "${OPT_FILTER_PATS[@]}"; do diag_args+=(-F "$pat"); done
    for extra in "${OPT_EXTRA_ARGS[@]}"; do diag_args+=("$extra"); done

    [[ "$quiet" -eq 0 ]] && echo "logstats stage: running $run_mode diagnostics against staged log ..." >&2

    if [[ "$run_mode" == "report" ]]; then
        logreport "$target_unpacked" "${diag_args[@]}"
    else
        "log$run_mode" "$target_unpacked" "${diag_args[@]}"
    fi

    if [[ "$keep" -eq 1 ]]; then
        echo "logstats stage: staged file retained at: $target_unpacked" >&2
    fi
}

# =============================================================================
# MODE: REPORT (Full Multi-Pass Diagnostic Battery)
# =============================================================================
logreport() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 || -z "$OPT_FILE" ]]; then
        cat <<'EOF'
usage: logstats report [FILE] [OPTIONS]
  Run a comprehensive diagnostic battery against a log file:
  Summary -> Gaps & Silences -> Rate Spikes -> Error Triage -> Frequent Templates -> Timeline.
EOF
        [[ $rc -eq 10 ]] && return 0
        return 1
    fi

    local file="$OPT_FILE"
    if [[ "$file" == "-" ]]; then
        # For stdin, stage to a temporary file first so multi-pass works
        local tmp_stdin
        tmp_stdin=$(_ls_mktemp) || return 1
        cat > "$tmp_stdin"
        file="$tmp_stdin"
        _ls_report_stdin_cleanup() { rm -f "$tmp_stdin"; }
        trap _ls_report_stdin_cleanup EXIT INT TERM HUP
    fi

    # Pass-through args
    local pass_args=()
    [[ -n "$OPT_RANGE" && "$OPT_RANGE" != "1:-1" ]] && pass_args+=(--range "$OPT_RANGE")
    [[ -n "$OPT_TOPN" && "$OPT_TOPN" != "10" ]] && pass_args+=(--top "$OPT_TOPN")
    [[ -n "$OPT_MINGAP" && "$OPT_MINGAP" != "1.0" ]] && pass_args+=(--min-gap "$OPT_MINGAP")
    [[ -n "$OPT_FMT" ]] && pass_args+=(--format "$OPT_FMT")
    [[ "$OPT_HEAD_TOKS" -gt 0 ]] && pass_args+=(--head-tokens "$OPT_HEAD_TOKS")
    [[ "$OPT_REQUIRE_TS" -eq 1 ]] && pass_args+=(--require-ts)
    [[ -n "$OPT_SKIP_UNTIL" ]] && pass_args+=(--skip-until "$OPT_SKIP_UNTIL")
    [[ -n "$OPT_SKIP_WHILE" ]] && pass_args+=(--skip-while "$OPT_SKIP_WHILE")
    for pat in "${OPT_IGNORE_PATS[@]}"; do pass_args+=(-I "$pat"); done
    for pat in "${OPT_FILTER_PATS[@]}"; do pass_args+=(-F "$pat"); done

    echo "################################################################################"
    echo "# COMPREHENSIVE LOG DIAGNOSTIC REPORT: ${OPT_FILE:-stdin}"
    echo "# Generated at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "################################################################################"
    echo ""

    echo ">>> SECTION 1: HEALTH & METRICS OVERVIEW"
    logsummary "$file" "${pass_args[@]}"
    echo ""

    echo ">>> SECTION 2: SILENCES, FREEZES & GAPS"
    loggaps "$file" "${pass_args[@]}"
    echo ""

    echo ">>> SECTION 3: RATE SPIKES & LOGGING FLOODS"
    logbursts "$file" "${pass_args[@]}"
    echo ""

    echo ">>> SECTION 4: ERROR ROOT-CAUSE TRIAGE"
    logerrors "$file" "${pass_args[@]}"
    echo ""

    echo ">>> SECTION 5: STRUCTURAL TEMPLATES & OUTLIERS"
    logrepeats "$file" "${pass_args[@]}"
    echo ""

    echo ">>> SECTION 6: ACTIVITY & ERROR TIMELINE"
    logtimeline "$file" "${pass_args[@]}"
    echo ""

    echo "################################################################################"
    echo "# END OF REPORT"
    echo "################################################################################"

    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: SUMMARY (Overview + Gaps + Errors + Templates)
# =============================================================================
logsummary() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats summary [FILE] [OPTIONS]
  Comprehensive diagnostic overview: duration, event rates, silences, error
  breakdown, first error anchor, and structural template frequencies.

Options:
  --top <N>             Number of top templates/silences to display (default: 10)
  --range <START:END>   Line range slice (e.g. 100:-1, 100:, :500, -500:)
  -s, --skip-until <P>  Skip lines until pattern P is encountered
  --skip-while <P>      Skip leading lines while matching pattern P
  --require-ts          Skip lines that do not have a valid timestamp
  -I, --ignore <ERE>    Ignore lines matching regex (can be specified multiple times)
  -F, --filter <ERE>    Only process lines matching regex
  --min-gap <SECS>      Minimum gap duration threshold in seconds (default: 1.0s)
  --format <FMT>        Override detected format (iso, slash, clf, apache, syslog, hdfs, epoch, time_only)
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local topn="$OPT_TOPN" mingap="$OPT_MINGAP"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || { [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1; }
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")

    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format detected in log sample" >&2
        echo "supported: iso, slash, clf, apache, syslog, hdfs, epoch, time_only (or force with --format)" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local tmp_p tmp_s
    tmp_p=$(_ls_mktemp) || return 1
    tmp_s=$(_ls_mktemp) || { rm -f "$tmp_p"; return 1; }

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)

    local ign_str="${OPT_IGNORE_PATS[*]}"
    local filt_str="${OPT_FILTER_PATS[*]}"

    echo "================================================================================"
    echo " LOG DIAGNOSTIC SUMMARY: ${OPT_FILE:-stdin}"
    echo " Format: $fmt | Window: lines $r_start..$r_end | Min-gap: ${mingap}s"
    echo "================================================================================"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v topn="$topn" -v mingap="$mingap" \
        -v req_ts="$OPT_REQUIRE_TS" -v head_toks="$OPT_HEAD_TOKS" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" \
        -v pf="$tmp_p" -v sf="$tmp_s" "$_LS_LIB"'
        function ins_gap(gap, ln1, ln2, t1, t2, content,    i) {
            if (gap < mingap || gap <= gaps[topn]) return
            i = topn
            while (i > 1 && gap > gaps[i - 1]) {
                gaps[i] = gaps[i-1]; gf[i] = gf[i-1]; gt[i] = gt[i-1]
                g1[i] = g1[i-1]; g2[i] = g2[i-1]; gl[i] = gl[i-1]
                i--
            }
            gaps[i] = gap; gf[i] = ln1; gt[i] = ln2
            g1[i] = t1; g2[i] = t2; gl[i] = content
            if (seen_gaps < topn) seen_gaps++
        }
        BEGIN {
            mon_init()
            for (i = 1; i <= topn; i++) gaps[i] = -1
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
            active_head = head_toks + 0
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            total_scanned++
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else { skipped_noise++; next }
            }
            if (s_while != "" && $0 ~ s_while) { skipped_noise++; next }
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) {
                    if ($0 ~ ign_arr[k]) { skipped_rule++; next }
                }
            }
            if (n_filt > 0) {
                matched_filt = 0
                for (k = 1; k <= n_filt; k++) {
                    if ($0 ~ filt_arr[k]) { matched_filt = 1; break }
                }
                if (!matched_filt) { skipped_rule++; next }
            }

            has_ts = ts_parse($0)
            if (!has_ts) {
                nots++
                if (req_ts) next
            } else {
                nts++
                e = G_E
                if (have_ts) {
                    delta = e - pe
                    if (delta < 0) neg_jumps++
                    else {
                        if (delta >= mingap) total_silence_time += delta
                        ins_gap(delta, pnr, NR, pts, G_SHOW, substr($0, 1, 90))
                    }
                } else {
                    first_ts = e
                    first_nr = NR
                    first_line = substr($0, 1, 90)
                }
                pe = e; pnr = NR; pts = G_SHOW; have_ts = 1
                last_ts = e; last_nr = NR; last_line = substr($0, 1, 90)
            }

            lvl = log_level($0)
            level_cnt[lvl]++
            if (lvl == "FATAL" || lvl == "ERROR") {
                total_errors++
                if (!first_err_line) {
                    first_err_nr = NR
                    first_err_ts = (has_ts ? G_SHOW : "L" NR)
                    first_err_line = substr($0, 1, 100)
                }
            }

            if (has_ts) {
                s = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
            } else {
                s = $0
            }
            sub(/^[ \t]+/, "", s)
            if (s != "") {
                # Probe first 3,000 lines for high cardinality
                if (samp_cnt < 3000) {
                    samp_cnt++
                    raw_sk = skel(s, 0)
                    samp_sk[raw_sk]++
                    if (samp_cnt == 3000 && active_head == 0) {
                        distinct_samp = 0
                        for (k in samp_sk) distinct_samp++
                        card_ratio = distinct_samp / 3000
                        if (card_ratio > 0.80) {
                            cardinality_alert = 1
                            active_head = 6 # Auto-clamp to 6 head tokens to collapse tail
                        }
                    }
                }

                sk = skel(s, active_head)
                if (cardinality_alert && n_uncollapsed < 3) {
                    uncollapsed[++n_uncollapsed] = substr($0, 1, 95)
                }

                # Bounded disk streaming protection (spill cap at 200,000 lines with 1-in-10 sampling beyond)
                written_lines++
                if (written_lines <= 200000 || (written_lines % 10 == 0)) {
                    c1 = s; kv = gsub(/[A-Za-z_][A-Za-z0-9_.]*=/, "&", c1)
                    c2 = s; dr = gsub(/[0-9]+/, "&", c2)
                    if (s ~ /^[[{<]/ || kv >= 3 || dr >= 6) print sk > sf
                    else                                   print sk > pf
                }
            }
        }
        END {
            if (total_scanned == 0) {
                print "No lines found in specified range."
                exit
            }
            printf "Lines Processed: %-10d (Timestamped: %d, Non-TS: %d, Ignored: %d)\n", \
                total_scanned, nts, nots, (skipped_noise + skipped_rule)
            
            if (have_ts) {
                dur = last_ts - first_ts
                printf "Time Span:       %s  ->  %s  (%s)\n", e2dt(first_ts, 0), e2dt(last_ts, 0), hms(dur)
                if (dur > 0 && nts > 1) {
                    printf "Event Rate:      %.2f lines/sec (%.1f lines/min)\n", nts / dur, (nts / dur) * 60
                }
                if (neg_jumps > 0) {
                    printf "WARNING:         %d negative time jumps detected (log is out of order)\n", neg_jumps
                }
            } else {
                print "Time Span:       (No valid timestamps detected in processed window)"
            }

            if (cardinality_alert) {
                print ""
                print "================================================================================"
                print "⚠️  HIGH CARDINALITY DETECTED: Log lines contain high dynamic variance (>80% unique)."
                print "   Auto-Adaptive Recovery: Clamped templates to leading 6 tokens to cluster call sites."
                print "   Sample lines with uncollapsing dynamic variance:"
                for (u = 1; u <= n_uncollapsed; u++) {
                    printf "     %d. %s\n", u, uncollapsed[u]
                }
                print "   Tip: Use --head-tokens <N> (e.g. -H 4) or ignore noisy lines with -I <regex>."
                print "================================================================================"
            }

            print ""
            print "--- Log Level Distribution ---"
            printf "  FATAL/CRIT: %-8d  ERROR: %-8d  WARN: %-8d  INFO: %-8d  DEBUG: %-8d\n", \
                level_cnt["FATAL"]+0, level_cnt["ERROR"]+0, level_cnt["WARN"]+0, level_cnt["INFO"]+0, level_cnt["DEBUG"]+0

            if (first_err_line != "") {
                print ""
                printf "--- First Error Anchor (Root Cause Candidate) ---\n"
                printf "  Line %d [%s]: %s\n", first_err_nr, first_err_ts, first_err_line
            }

            if (seen_gaps > 0) {
                print ""
                printf "--- Top Silences / Gaps (>= %.1fs) ---\n", mingap
                for (i = 1; i <= seen_gaps; i++) {
                    printf "  %2d. %-10s (L%-6d -> L%-6d)  %s -> %s\n      Wake: %s\n", \
                        i, hum(gaps[i]), gf[i], gt[i], g1[i], g2[i], gl[i]
                }
            }
        }'

    local fmt_awk='{ c = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if (length($0) > 95) $0 = substr($0, 1, 95) "..."
                printf "  %7d (%5.1f%%)  %s\n", c, (c / total_lines) * 100, $0 }'

    local total_plain=0 total_struct=0
    [[ -s "$tmp_p" ]] && total_plain=$(wc -l < "$tmp_p" | tr -d ' ')
    [[ -s "$tmp_s" ]] && total_struct=$(wc -l < "$tmp_s" | tr -d ' ')

    print_templates() {
        local tmp_file="$1" heading="$2" tot="$3"
        if [[ -s "$tmp_file" ]]; then
            echo ""
            echo "--- $heading (Top $topn) ---"
            local uniq_cnt
            uniq_cnt=$(LC_ALL=C sort "$tmp_file" | uniq | wc -l | tr -d ' ')
            echo "  (Distinct templates: $uniq_cnt | Total messages: $tot)"
            LC_ALL=C sort "$tmp_file" | uniq -c | LC_ALL=C sort -rn | head -n "$topn" | \
                awk -v total_lines="$tot" "$fmt_awk"
        fi
    }

    print_templates "$tmp_p" "Frequent Line Templates" "$total_plain"
    print_templates "$tmp_s" "Structured Payloads (JSON / XML / KV)" "$total_struct"

    rm -f "$tmp_p" "$tmp_s"
    [[ "$file" =~ logstats\. ]] && rm -f "$file"
}

# =============================================================================
# MODE: GAPS & SILENCES (Freeze / Pause Detection)
# =============================================================================
loggaps() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats gaps [FILE] [OPTIONS]
  Identify freezes, hangs, and pauses between consecutive log lines.

Options:
  --min-gap <SECS>      Minimum silence duration threshold (default: 1.0s)
  --top <N>             Show top N longest gaps (default: 10)
  --range <START:END>   Line range slice
  -s, --skip-until <P>  Skip startup lines until pattern P
  -I, --ignore <ERE>    Ignore lines matching regex
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local topn="$OPT_TOPN" mingap="$OPT_MINGAP"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || { [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1; }
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format detected" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"

    echo "--- Top Silences & Gaps (>= ${mingap}s) in ${OPT_FILE:-stdin} ---"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v topn="$topn" -v mingap="$mingap" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" "$_LS_LIB"'
        function ins_gap(gap, ln1, ln2, t1, t2, content,    i) {
            if (gap < mingap || gap <= gaps[topn]) return
            i = topn
            while (i > 1 && gap > gaps[i - 1]) {
                gaps[i] = gaps[i-1]; gf[i] = gf[i-1]; gt[i] = gt[i-1]
                g1[i] = g1[i-1]; g2[i] = g2[i-1]; gl[i] = gl[i-1]
                i--
            }
            gaps[i] = gap; gf[i] = ln1; gt[i] = ln2
            g1[i] = t1; g2[i] = t2; gl[i] = content
            if (seen_gaps < topn) seen_gaps++
        }
        BEGIN {
            mon_init()
            for (i = 1; i <= topn; i++) gaps[i] = -1
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }
            if (!ts_parse($0)) next
            e = G_E
            if (have_ts) {
                delta = e - pe
                if (delta >= mingap) {
                    total_gaps++
                    total_gap_sec += delta
                    ins_gap(delta, pnr, NR, pts, G_SHOW, substr($0, 1, 100))
                }
            } else {
                first_ts = e
            }
            pe = e; pnr = NR; pts = G_SHOW; have_ts = 1
            last_ts = e
        }
        END {
            if (seen_gaps == 0) {
                printf "No gaps >= %.1fs found across %s duration.\n", mingap, hms(last_ts - first_ts)
                exit
            }
            tot_dur = last_ts - first_ts
            printf "Found %d silences >= %.1fs  (Total silent time: %s, %.1f%% of total run)\n\n", \
                total_gaps, mingap, hms(total_gap_sec), (tot_dur > 0 ? (total_gap_sec / tot_dur) * 100 : 0)

            for (i = 1; i <= seen_gaps; i++) {
                printf "%3d. %10s   Line %d -> %d\n     Start: %s\n     End:   %s\n     Wakes with: %s\n\n", \
                    i, hum(gaps[i]), gf[i], gt[i], g1[i], g2[i], gl[i]
            }
        }'
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: BURSTS & SPIKES (Rate Spikes & Message Floods)
# =============================================================================
logbursts() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats bursts [FILE] [OPTIONS]
  Detect peak log rates (lines/sec), message floods, and runaway loops.

Options:
  --top <N>             Show top N peak intervals (default: 10)
  --range <START:END>   Line range slice
  -s, --skip-until <P>  Skip startup lines until pattern P
  -I, --ignore <ERE>    Ignore lines matching regex
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local topn="$OPT_TOPN"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || { [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1; }
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format detected" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"

    echo "--- Peak Burst Intervals (Top $topn 1-Second Windows) in ${OPT_FILE:-stdin} ---"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v topn="$topn" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" "$_LS_LIB"'
        BEGIN {
            mon_init()
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }
            if (!ts_parse($0)) next
            sec_bucket = int(G_E)
            sec_count[sec_bucket]++
            if (!sec_first_sample[sec_bucket]) {
                sec_first_sample[sec_bucket] = substr($0, 1, 95)
                sec_ts_str[sec_bucket] = G_SHOW
            }
        }
        END {
            for (sec in sec_count) {
                printf "%d\t%s\t%s\n", sec_count[sec], sec_ts_str[sec], sec_first_sample[sec]
            }
        }' | LC_ALL=C sort -t $'\t' -k1,1rn | head -n "$topn" | awk -F '\t' '
        BEGIN { printf "   Rank   Lines/sec   Timestamp                Sample Line\n--------------------------------------------------------------------------------\n" }
        {
            cnt = $1; ts = $2; sample = $3
            printf "   %3d.   %7d/s   %-23s  %s\n", ++r, cnt, ts, sample
        }'
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: ERRORS & TRIAGE (Root Cause & Error Patterns)
# =============================================================================
logerrors() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats errors [FILE] [OPTIONS]
  Isolate first error root-cause context, error rates, and recurring error templates.

Options:
  --top <N>             Show top N error templates (default: 10)
  --range <START:END>   Line range slice
  -s, --skip-until <P>  Skip startup lines until pattern P
  -I, --ignore <ERE>    Ignore lines matching regex
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local topn="$OPT_TOPN"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || { [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1; }
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        fmt="iso"
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"
    local tmp_err
    tmp_err=$(_ls_mktemp) || return 1

    echo "--- Error & Root Cause Triage for ${OPT_FILE:-stdin} ---"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v topn="$topn" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" -v ef="$tmp_err" "$_LS_LIB"'
        BEGIN {
            mon_init()
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }

            lvl = log_level($0)
            if (lvl == "FATAL" || lvl == "ERROR" || lvl == "WARN") {
                lvl_count[lvl]++
            }

            if (lvl == "FATAL" || lvl == "ERROR") {
                err_total++
                if (err_total == 1) {
                    first_err_nr = NR
                    first_err_line = $0
                    for (c = 1; c <= 5; c++) {
                        if (c_buf[(NR - 5 + c - 1) % 5] != "")
                            lead_buf[c] = c_buf[(NR - 5 + c - 1) % 5]
                    }
                }
                has_ts = ts_parse($0)
                if (has_ts) s = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
                else s = $0
                sub(/^[ \t]+/, "", s)
                if (s != "") print skel(s) > ef
            }
            c_buf[NR % 5] = sprintf("L%-6d  %s", NR, substr($0, 1, 95))
        }
        END {
            printf "Error Breakdown:  FATAL/CRIT: %d  |  ERROR: %d  |  WARN: %d\n", \
                lvl_count["FATAL"]+0, lvl_count["ERROR"]+0, lvl_count["WARN"]+0

            if (err_total == 0) {
                print "\nNo FATAL or ERROR lines detected."
                exit
            }

            print ""
            printf "================================================================================\n"
            printf " FIRST ERROR ROOT-CAUSE CONTEXT (Line %d)\n", first_err_nr
            printf "================================================================================\n"
            for (c = 1; c <= 5; c++) {
                if (lead_buf[c] != "") printf "  %s\n", lead_buf[c]
            }
            printf ">> L%-6d  %s\n", first_err_nr, first_err_line
            printf "================================================================================\n"
        }'

    if [[ -s "$tmp_err" ]]; then
        local tot_e
        tot_e=$(wc -l < "$tmp_err" | tr -d ' ')
        echo ""
        echo "--- Recurring Error Templates (Top $topn) ---"
        LC_ALL=C sort "$tmp_err" | uniq -c | LC_ALL=C sort -rn | head -n "$topn" | \
            awk -v total_lines="$tot_e" '{
                c = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if (length($0) > 95) $0 = substr($0, 1, 95) "..."
                printf "  %7d (%5.1f%%)  %s\n", c, (c / total_lines) * 100, $0
            }'
    fi
    rm -f "$tmp_err"
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: REPEATS & TEMPLATES (Pattern Frequency & Rare Anomalies)
# =============================================================================
logrepeats() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats repeats [FILE] [OPTIONS]
  Extract structural line templates, pattern distributions, or rare anomalies.

Options:
  --top <N>             Number of templates to display (default: 10)
  --head-tokens <N>     Cluster templates by first N words (e.g. -H 5)
  --rare, --outliers    Show rare anomalies (templates appearing <= 2 times)
  --range <START:END>   Line range slice
  -s, --skip-until <P>  Skip startup lines until pattern P
  -I, --ignore <ERE>    Ignore lines matching regex
  -F, --filter <ERE>    Only process lines matching regex
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local topn="$OPT_TOPN" rare="$OPT_RARE"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || { [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1; }
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then fmt="iso"; fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"

    local tmp_t
    tmp_t=$(_ls_mktemp) || return 1

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v head_toks="$OPT_HEAD_TOKS" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" -v tf="$tmp_t" "$_LS_LIB"'
        BEGIN {
            mon_init()
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
            active_head = head_toks + 0
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }

            has_ts = ts_parse($0)
            if (has_ts) s = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
            else s = $0
            sub(/^[ \t]+/, "", s)
            if (s != "") {
                if (samp_cnt < 3000) {
                    samp_cnt++
                    raw_sk = skel(s, 0)
                    samp_sk[raw_sk]++
                    if (samp_cnt == 3000 && active_head == 0) {
                        distinct_samp = 0
                        for (k in samp_sk) distinct_samp++
                        if ((distinct_samp / 3000) > 0.80) {
                            cardinality_alert = 1
                            active_head = 6
                        }
                    }
                }

                sk = skel(s, active_head)
                if (cardinality_alert && n_uncollapsed < 3) {
                    uncollapsed[++n_uncollapsed] = substr($0, 1, 95)
                }

                written_lines++
                if (written_lines <= 200000 || (written_lines % 10 == 0)) {
                    print sk > tf
                }
            }
        }
        END {
            if (cardinality_alert) {
                print "================================================================================" > "/dev/stderr"
                print "⚠️  HIGH CARDINALITY ALERT: Log templates showed high variance (>80% distinct lines)." > "/dev/stderr"
                print "   Auto-Adaptive Clamping enabled (clamped to leading 6 tokens to cluster call sites)." > "/dev/stderr"
                print "   Sample lines with uncollapsing dynamic variance:" > "/dev/stderr"
                for (u = 1; u <= n_uncollapsed; u++) {
                    printf "     %d. %s\n", u, uncollapsed[u] > "/dev/stderr"
                }
                print "   Tip: Use --head-tokens <N> (e.g. -H 4) or ignore noisy lines with -I <regex>." > "/dev/stderr"
                print "================================================================================" > "/dev/stderr"
            }
        }'

    if [[ ! -s "$tmp_t" ]]; then
        echo "logstats: no lines to process" >&2
        rm -f "$tmp_t"
        return 1
    fi

    local tot_lines uniq_cnt
    tot_lines=$(wc -l < "$tmp_t" | tr -d ' ')
    uniq_cnt=$(LC_ALL=C sort "$tmp_t" | uniq | wc -l | tr -d ' ')

    if [[ "$rare" -eq 1 ]]; then
        echo "--- Rare Outliers / Anomalies (Templates with <= 2 Occurrences) ---"
        echo "Total lines: $tot_lines | Distinct templates: $uniq_cnt"
        echo ""
        LC_ALL=C sort "$tmp_t" | uniq -c | awk '$1 <= 2' | head -n "$topn" | \
            awk '{
                c = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                printf "  [%dx]  %s\n", c, $0
            }'
    else
        echo "--- Frequent Structural Templates (Top $topn) ---"
        echo "Total lines: $tot_lines | Distinct templates: $uniq_cnt (Compression ratio: $(awk -v t="$tot_lines" -v u="$uniq_cnt" 'BEGIN{printf "%.1fx", (u>0 ? t/u : 1)}'))"
        echo ""
        LC_ALL=C sort "$tmp_t" | uniq -c | LC_ALL=C sort -rn | head -n "$topn" | \
            awk -v total_lines="$tot_lines" '{
                c = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if (length($0) > 95) $0 = substr($0, 1, 95) "..."
                printf "  %7d (%5.1f%%)  %s\n", c, (c / total_lines) * 100, $0
            }'
    fi
    rm -f "$tmp_t"
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: TIMELINE (ASCII Activity & Error Histogram)
# =============================================================================
logtimeline() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 ]]; then
        cat <<'EOF'
usage: logstats timeline [FILE] [OPTIONS]
  Display an ASCII activity and error histogram across time buckets.

Options:
  --range <START:END>   Line range slice
  -s, --skip-until <P>  Skip startup lines until pattern P
  -I, --ignore <ERE>    Ignore lines matching regex
EOF
        return 0
    elif [[ $rc -ne 0 ]]; then return 1; fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format detected" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"

    echo "--- Activity & Error Timeline for ${OPT_FILE:-stdin} ---"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" "$_LS_LIB"'
        BEGIN {
            mon_init()
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
        }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }
            if (!ts_parse($0)) next
            e = G_E
            if (!have_first) { first_e = e; have_first = 1 }
            last_e = e
            events[++total_ev] = e
            lvl = log_level($0)
            if (lvl == "FATAL" || lvl == "ERROR") is_err[total_ev] = 1
        }
        END {
            if (total_ev < 2) {
                print "Not enough timestamped events for timeline."
                exit
            }
            dur = last_e - first_e
            nbuckets = 16
            bucket_sz = dur / nbuckets
            if (bucket_sz <= 0) bucket_sz = 1

            for (i = 1; i <= total_ev; i++) {
                b = int((events[i] - first_e) / bucket_sz) + 1
                if (b > nbuckets) b = nbuckets
                b_cnt[b]++
                if (is_err[i]) b_err[b]++
                if (b_cnt[b] > max_cnt) max_cnt = b_cnt[b]
            }

            bar_max = 24
            for (b = 1; b <= nbuckets; b++) {
                b_start = first_e + (b - 1) * bucket_sz
                b_len = (max_cnt > 0 ? int((b_cnt[b] / max_cnt) * bar_max) : 0)
                bar = ""
                for (j = 1; j <= b_len; j++) bar = bar "█"
                for (j = b_len + 1; j <= bar_max; j++) bar = bar "░"
                
                err_str = (b_err[b] > 0 ? sprintf(" (%d errors)", b_err[b]) : "")
                printf "%s  [%7d lines]  [%s]%s\n", e2dt(b_start, 0), b_cnt[b]+0, bar, err_str
            }
        }'
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: AROUND (Temporal Window Context around Matches)
# =============================================================================
logaround() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 || -z "$OPT_FILE" || ${#OPT_EXTRA_ARGS[@]} -eq 0 ]]; then
        cat <<'EOF'
usage: logstats around FILE PATTERN [--secs N]
  Extract every line within ±SECS seconds of each PATTERN match (ERE).
  Overlapping windows merge; matched lines prefixed with >>.
EOF
        [[ $rc -eq 10 ]] && return 0
        return 1
    fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local pat="${OPT_EXTRA_ARGS[0]}"
    local secs="${OPT_SECS:-5}"
    if [[ ${#OPT_EXTRA_ARGS[@]} -ge 2 && "${OPT_EXTRA_ARGS[1]}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        secs="${OPT_EXTRA_ARGS[1]}"
    fi

    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    if [[ $? -eq 2 ]]; then
        echo "logstats: invalid pattern '$pat'" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format in log" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)

    local ivs
    ivs=$(_lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v pat="$pat" -v secs="$secs" "$_LS_LIB"'
        BEGIN { mon_init() }
        {
            if (ts_parse($0)) { pe = G_E; pts = G_SHOW; have = 1 }
            if ($0 ~ pat && have) {
                lo = pe - secs; hi = pe + secs
                if (n > 0 && lo <= U[n]) {
                    if (hi > U[n]) U[n] = hi
                } else {
                    n++; L[n] = lo; U[n] = hi; MN[n] = NR; MT[n] = pts
                }
            }
        }
        END {
            for (i = 1; i <= n; i++)
                printf "%.6f|%.6f|%d|%s\n", L[i], U[i], MN[i], MT[i]
        }')

    if [[ -z "$ivs" ]]; then
        echo "logstats: no timestamped matches for '$pat'" >&2
        return 1
    fi
    ivs=${ivs//$'\n'/|}

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v ivss="$ivs" -v pat="$pat" -v secs="$secs" "$_LS_LIB"'
        BEGIN {
            mon_init()
            nf = split(ivss, f, "|")
            ni = int(nf / 4)
            for (i = 0; i < ni; i++) {
                L[i + 1] = f[i * 4 + 1] + 0; U[i + 1] = f[i * 4 + 2] + 0
                MN[i + 1] = f[i * 4 + 3]; MT[i + 1] = f[i * 4 + 4]
            }
        }
        {
            if (ts_parse($0)) {
                e = G_E
                if (idx == 0) idx = 1
                while (idx <= ni && e > U[idx]) idx++
                if (idx > ni) exit
                if (e >= L[idx]) { member = 1; cur = idx }
                else member = 0
            }
            if (!member) next
            if (cur != lastc) {
                if (lastc) print ""
                printf "--- around L%s  %s  (±%ss) ---\n", MN[cur], MT[cur], secs
                lastc = cur
            }
            printf "%s %s\n", ($0 ~ pat ? ">>" : "  "), $0
        }'
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: LATENCY (Percentiles of Numbers in Matching Lines)
# =============================================================================
loglatency() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@"
    local rc=$?
    if [[ $rc -eq 10 || -z "$OPT_FILE" || ${#OPT_EXTRA_ARGS[@]} -eq 0 ]]; then
        cat <<'EOF'
usage: logstats latency FILE PATTERN [UNIT=m|h|s]
  Percentiles (min, p50, p90, p95, p99, max) of the first number on each line
  matching PATTERN; overall + chronological per-bucket table.
EOF
        [[ $rc -eq 10 ]] && return 0
        return 1
    fi

    local file
    file=$(_ls_prepare_input "$OPT_FILE") || return 1
    local pat="${OPT_EXTRA_ARGS[0]}"
    local unit="${OPT_UNIT:-m}"
    if [[ ${#OPT_EXTRA_ARGS[@]} -ge 2 ]]; then
        unit="${OPT_EXTRA_ARGS[1]}"
    fi

    local unitdesc
    case "$unit" in
        m) unitdesc=minute ;;
        h) unitdesc=hour ;;
        s) unitdesc=second ;;
        *) echo "logstats: UNIT must be m, h, or s" >&2; [[ "$OPT_FILE" == "-" ]] && rm -f "$file"; return 1 ;;
    esac

    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    if [[ $? -eq 2 ]]; then
        echo "logstats: invalid pattern '$pat'" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logstats: no recognizable timestamp format in log" >&2
        [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)

    local zs tzo=0
    zs=$(date +%z 2>/dev/null)
    if [[ "$zs" =~ ^([+-])([0-9][0-9])([0-9][0-9])$ ]]; then
        tzo=$((10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60))
        [[ "${BASH_REMATCH[1]}" == "-" ]] && tzo=$((-tzo))
    fi

    local tmp tmpv tmpb
    tmp=$(_ls_mktemp) || return 1
    tmpv=$(_ls_mktemp) || { rm -f "$tmp"; return 1; }
    tmpb=$(_ls_mktemp) || { rm -f "$tmp" "$tmpv"; return 1; }

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v pat="$pat" -v unit="$unit" -v tzo="$tzo" "$_LS_LIB"'
        function e2b(e, off,    s) {
            s = e2dt(e, off)
            if (unit == "h") return substr(s, 1, 13)
            if (unit == "s") return s
            return substr(s, 1, 16)
        }
        BEGIN { mon_init() }
        {
            if (!ts_parse($0)) next
            rest = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
            if (!match(rest, pat)) next
            matched_str = substr(rest, RSTART, RLENGTH)
            rem = substr(rest, RSTART + RLENGTH)
            num = ""
            if (match(matched_str, /[0-9]+(\.[0-9]+)?/)) {
                num = substr(matched_str, RSTART, RLENGTH)
            } else if (match(rem, /[0-9]+(\.[0-9]+)?/)) {
                num = substr(rem, RSTART, RLENGTH)
            }
            if (num != "") {
                printf "%s\t%s\n", e2b(G_E, (fmt == "epoch" ? tzo : 0)), num
            }
        }' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2g > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        echo "logstats: no samples found matching '$pat' with a numeric value" >&2
        rm -f "$tmp" "$tmpv" "$tmpb"
        return 1
    fi

    echo "--- Latency Statistics for ${file} ---"
    echo "Pattern: '$pat'  (first number after timestamp)"
    echo ""

    cut -d $'\t' -f2 "$tmp" | LC_ALL=C sort -g > "$tmpv"
    awk '
        function pct(p,    i) {
            i = int((p * n + 99) / 100)
            if (i < 1) i = 1
            return v[i]
        }
        { v[NR] = $1 + 0; sum += v[NR] }
        END {
            n = NR
            printf "Samples: %d\n", n
            printf "Overall: min %.3f | p50 %.3f | p90 %.3f | p95 %.3f | p99 %.3f | max %.3f | avg %.3f\n", \
                v[1], pct(50), pct(90), pct(95), pct(99), v[n], sum / n
        }' "$tmpv"

    awk -F '\t' '
        function pi(p,    i) {
            i = int((p * cnt + 99) / 100)
            if (i < 1) i = 1
            return vals[i]
        }
        function flush() {
            if (!cnt) return
            printf "%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n", cur, cnt, vals[1], pi(50), pi(95), pi(99), vals[cnt]
            split("", vals)
            cnt = 0
        }
        $1 != cur { flush(); cur = $1 }
        { vals[++cnt] = $2 + 0 }
        END { flush() }' "$tmp" > "$tmpb"

    local fmt_out='{ printf "%s  n=%-6d min %8.3f  p50 %8.3f  p95 %8.3f  p99 %8.3f  max %8.3f\n", $1, $2, $3, $4, $5, $6, $7 }'
    echo ""
    echo "--- Worst 10 ${unitdesc}s by p99:"
    LC_ALL=C sort -t $'\t' -k6,6gr "$tmpb" | head -n 10 | awk -F '\t' "$fmt_out"
    echo ""
    echo "--- Per-${unitdesc} Chronological Breakdown:"
    awk -F '\t' "$fmt_out" "$tmpb"

    rm -f "$tmp" "$tmpv" "$tmpb"
    [[ "$OPT_FILE" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: SNIFF (Format & Structure Inspector)
# =============================================================================
logsniff() {
    _ls_check_env || return 1
    local input_target="${1:--}"
    local file
    file=$(_ls_prepare_input "$input_target") || return 1
    local fmt
    fmt=$(_ls_sniff "$file")
    echo "Detected Timestamp Format: $fmt"
    if [[ "$fmt" == "none" ]]; then
        [[ "$input_target" == "-" ]] && rm -f "$file"
        return 1
    fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)

    echo ""
    echo "Sample Parsing & Skeleton Normalization (First 5 valid lines):"
    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" "$_LS_LIB"'
        BEGIN { mon_init() }
        {
            if (ts_parse($0)) {
                valid++
                printf "--------------------------------------------------------------------------------\n"
                printf "Raw Line:       %s\n", $0
                printf "Timestamp Token:%s (start=%d, len=%d)\n", G_SHOW, G_S, G_L
                printf "Parsed Epoch:   %.3f (%s)\n", G_E, e2dt(G_E, 0)
                s = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
                sub(/^[ \t]+/, "", s)
                printf "Masked Template:%s\n", skel(s, 0)
                if (valid >= 5) exit
            }
        }'
    [[ "$input_target" == "-" ]] && rm -f "$file"
}

# =============================================================================
# MODE: SLICE (Fast Streaming Filter with Rule Evaluation)
# =============================================================================
logslice() {
    _ls_check_env || return 1
    _ls_parse_filter_args "$@" || return 1
    local file="$OPT_FILE"
    local range_res
    range_res=$(_ls_resolve_range "$OPT_RANGE" "$file") || return 1
    local r_start r_end
    r_start=$(echo "$range_res" | cut -d' ' -f1)
    r_end=$(echo "$range_res" | cut -d' ' -f2)

    local fmt="$OPT_FMT"
    [[ -z "$fmt" ]] && fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then fmt="iso"; fi

    local cur_yr cur_m cur_d
    cur_yr=$(date +%Y); cur_m=$(date +%m); cur_d=$(date +%d)
    local ign_str="${OPT_IGNORE_PATS[*]}" filt_str="${OPT_FILTER_PATS[*]}"

    _lgz_cat "$file" | LC_ALL=C "$_LS_AWK" -v fmt="$fmt" -v yr="$cur_yr" -v cur_m="$cur_m" -v cur_d="$cur_d" \
        -v r_start="$r_start" -v r_end="$r_end" -v req_ts="$OPT_REQUIRE_TS" \
        -v s_until="$OPT_SKIP_UNTIL" -v s_while="$OPT_SKIP_WHILE" \
        -v ign_str="$ign_str" -v filt_str="$filt_str" "$_LS_LIB"'
        BEGIN {
            mon_init()
            n_ign = split(ign_str, ign_arr, " ")
            n_filt = split(filt_str, filt_arr, " ")
            until_matched = (s_until == "" ? 1 : 0)
        }
        NR < r_start { next }
        r_end > 0 && NR > r_end { next }
        {
            if (!until_matched) {
                if ($0 ~ s_until) until_matched = 1
                else next
            }
            if (s_while != "" && $0 ~ s_while) next
            if (n_ign > 0) {
                for (k = 1; k <= n_ign; k++) if ($0 ~ ign_arr[k]) next
            }
            if (n_filt > 0) {
                mf = 0; for (k = 1; k <= n_filt; k++) if ($0 ~ filt_arr[k]) { mf = 1; break }
                if (!mf) next
            }
            if (req_ts && !ts_parse($0)) next
            print $0
        }'
}

# =============================================================================
# MODE: EXAMPLES (Real-World Operational Playbooks & Recipes)
# =============================================================================
logexamples() {
    cat <<'EOF'
================================================================================
 LOGSTATS REAL-WORLD OPERATIONAL RECIPES & EXAMPLES
================================================================================

1. PRODUCTION GZIP/COMPRESSED STAGING & INCIDENT TRIAGE
--------------------------------------------------------------------------------
# Problem: You are on a production host with a 2GB gzip log in /var/log/app/.
# You do not have write access to /var/log, and decompressing in-place could fill disk.
# Solution: Staging orchestrator copies file to /tmp or /dev/shm, uncompresses,
# runs the full multi-pass diagnostic report, and deletes staged files on exit.

  # Hands-off triage: Stage, decompress, generate full report, and auto-clean
  logstats stage /var/log/app/app.log.2026-08-23.gz --report

  # Stage to RAM disk (/dev/shm) for max speed, ignore noise, and find silences >= 3s
  logstats stage -W /dev/shm /var/log/app.log.gz gaps --min-gap 3s -I "Heartbeat"

  # Stage, unpack, run summary, but KEEP the unpacked file for manual review
  logstats stage --keep /var/log/app/app.log.gz summary

2. FREEZES, HANGS & SILENCES HUNTING (Finding Gaps)
--------------------------------------------------------------------------------
# Problem: A service mysteriously stopped responding or dropped connections.
# Solution: Find all time deltas between consecutive log lines.

  # Find top 10 longest silences in log file
  logstats gaps production.log

  # Find all pauses >= 5 seconds, ignoring healthcheck spam
  logstats gaps production.log --min-gap 5s -I "kube-probe" -I "healthcheck"

  # Check silences in compressed logs without staging
  logstats gaps app.log.gz --top 20

3. BURSTS, RUNAWAY LOOPS & RETRY STORMS
--------------------------------------------------------------------------------
# Problem: System experienced a traffic surge, infinite loop, or disk space flood.
# Solution: 1-second bucketing detects peak message velocity and the culprit line.

  # Find the 10 worst peak logging intervals (lines/sec)
  logstats bursts app.log --top 10

  # Scan for burst spikes only after startup sequence completed
  logstats bursts app.log -s "Server initialization complete"

4. ROOT CAUSE & FIRST-ERROR ANCHOR (Error Triage)
--------------------------------------------------------------------------------
# Problem: Cascading failure produced 20,000 ERROR lines. The 10,000th error
# is useless noise; you need the FIRST error and the lead-up context.
# Solution: 'errors' mode extracts the first error anchor + 5 lines of lead-up.

  # Isolate first error context, log-level counts, and recurring error templates
  logstats errors app.log

  # Isolate errors within a specific line range slice (e.g. lines 5000 to 15000)
  logstats errors app.log --range 5000:15000

5. TEMPLATE FREQUENCIES, DYNAMIC XML/JSON & ANOMALIES
--------------------------------------------------------------------------------
# Problem: 100,000 log lines contain unique XML (<Order id="98234">) and JSON
# payloads, making standard 'sort | uniq' fail because every line is unique.
# Solution: 4-tier structural normalization collapses dynamic values into templates.

  # View top 15 recurring structural templates across plain & structured payloads
  logstats repeats app.log --top 15

  # OUTLIER DETECTION: Find rare 1-off messages (panics, assertions, edge cases)
  logstats repeats app.log --rare

  # Ignore non-standard logging (raw stdout prints without timestamps)
  logstats repeats app.log --require-ts

6. TEMPORAL CONTEXT EXTRACTION (Window around Events)
--------------------------------------------------------------------------------
# Problem: A critical event happened at 14:05:02. You need all log lines within
# ±10 seconds across all worker threads to see what else was happening.
# Solution: 'around' extracts all lines in that time window and merges clusters.

  # Extract ±5 seconds around all "FATAL" or "Panic" occurrences
  logstats around app.log "FATAL|Panic" --secs 5

  # Extract ±10 seconds around an order checkout failure
  logstats around app.log "Payment failed" --secs 10

7. LATENCY PERCENTILES & ENDPOINT TIMINGS
--------------------------------------------------------------------------------
# Problem: Logs contain timing lines like 'request took 45.2 ms'. You need p50,
# p95, and p99 percentiles overall and broken down chronologically.
# Solution: 'latency' parses numeric samples and computes statistical percentiles.

  # Compute overall and minutely latency percentiles
  logstats latency app.log "query took [0-9.]+" --unit m

  # Compute hourly latency for payment gateway calls
  logstats latency app.log "gateway latency=[0-9.]+" --unit h

8. STREAMING & KUBERNETES / DOCKER PIPELINES
--------------------------------------------------------------------------------
# Problem: Streaming logs from kubectl, docker, or journalctl in real time.
# Solution: Pass '-' as the filename to read from STDIN.

  # Live Kubernetes container diagnostics
  kubectl logs -n prod deploy/api --since=1h | logstats summary -

  # Stream journalctl logs, skip startup, and find error root-cause
  journalctl -u my-service -b | logstats errors - -s "Started MyService"

9. HIGH-CARDINALITY LOGS (When standard uniques fail on 2GB+ files)
--------------------------------------------------------------------------------
# Problem: 10 million lines of free-form text or unstructured dumps where
# stripping numbers still leaves every line unique.
# Solution: Head-token clustering isolates the static call-site in source code,
# and in-flight circuit breakers prevent disk/memory exhaustion.

  # Cluster lines by the first 5 words of each log message
  logstats repeats app.log --head-tokens 5

  # Run full summary with head-token clamping
  logstats summary app.log -H 6

  # Combine head tokens with ignore rules to filter high-entropy noise
  logstats repeats app.log -H 4 -I "transaction_id"

================================================================================
EOF
}

# =============================================================================
# Backward Compatibility Wrapper
# =============================================================================
logfilestats() {
    logsummary "$@"
}

# =============================================================================
# Main Dispatcher (when executed directly or invoked as logstats)
# =============================================================================
logstats() {
    if [[ $# -eq 0 || "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
        cat <<'EOF'
logstats — Universal Log File Intelligence & Diagnostics Toolkit

Usage:
  logstats [MODE] [OPTIONS] [FILE]
  cat log.txt | logstats [MODE] [OPTIONS] -

Diagnostic Modes:
  summary    (default) Overall health, event rates, silences, error breakdown, templates
  report     Full multi-pass diagnostic report (Summary + Gaps + Spikes + Errors + Timeline)
  gaps       Longest silences, freezes, and pauses between log lines
  bursts     Peak log-rate intervals (lines/sec), message floods, and loops
  errors     First error anchor (root-cause context), error rates, error templates
  repeats    Structural template frequencies (--rare for 1-off anomalies)
  timeline   ASCII activity and error histogram across chronological time buckets
  around     Time context window (±N seconds) around pattern matches
  latency    Percentiles (p50, p95, p99) of numbers in matching lines
  sniff      Inspect timestamp format, prefix boundaries, and mask previews
  slice      Stream log lines with rules (skip-until, ignore, filter, range)
  stage      Production orchestrator: copy to owned path -> unpack -> run -> auto-clean
  examples   Show real-world operational playbooks and incident triage recipes

Common Filtering Options (available across modes):
  --range <START:END>   Line range slice (e.g. 100:-1, 100:, :500, -1000:)
  -s, --skip-until <P>  Skip startup lines until pattern P is matched
  --skip-while <P>      Skip leading lines while matching pattern P
  --require-ts          Ignore non-timestamped lines (stdout prints, stack traces)
  -I, --ignore <ERE>    Ignore lines matching regex (can be specified multiple times)
  -F, --filter <ERE>    Process only lines matching regex
  -n, --top <N>         Number of results to display (default: 10)
  --min-gap <SECS>      Minimum silence duration threshold (default: 1.0s)
  --format <FMT>        Override auto-detected format (iso, slash, clf, apache, syslog, epoch, etc.)

Staging Orchestrator Options (for 'logstats stage' or '--stage'):
  -W, --workdir <DIR>   Staging base directory (default: $TMPDIR or /tmp)
  --keep, --no-cleanup  Retain unpacked files in staging directory on exit
  --report, --all       Run full multi-pass diagnostic report
  --force               Bypass disk space headroom safety check

Examples:
  logstats app.log                                # Standard full diagnostics
  logstats report app.log.gz                      # Full multi-pass incident report
  logstats stage /var/log/app.log.gz --report     # Stage, unpack, report & auto-clean
  logstats gaps app.log.gz --min-gap 5s           # Silences >= 5 seconds
  logstats bursts app.log --top 10                # Worst 10 traffic spikes
  logstats errors app.log                         # Root cause anchor + error templates
  logstats repeats app.log --rare                 # Identify 1-off anomalous messages
  logstats timeline app.log                       # Visual ASCII activity histogram
  logstats around app.log "FATAL" --secs 10       # ±10s context around FATAL
  logstats latency app.log "took [0-9.]+" --unit m  # Minutely query latency percentiles
  logstats slice app.log -s "Server ready"        # Stream logs after startup
EOF
        return 0
    fi

    # Check for --stage flag in arguments
    local has_stage=0
    for arg in "$@"; do
        if [[ "$arg" == "--stage" ]]; then
            has_stage=1; break
        fi
    done
    if [[ "$has_stage" -eq 1 ]]; then
        local filtered_args=()
        for arg in "$@"; do
            [[ "$arg" != "--stage" ]] && filtered_args+=("$arg")
        done
        logstage "${filtered_args[@]}"
        return $?
    fi

    local mode="$1"
    case "$mode" in
        summary|report|gaps|bursts|errors|repeats|timeline|around|latency|sniff|slice|stage|examples)
            shift
            "log$mode" "$@" ;;
        --examples|-e)
            logexamples ;;
        -*)
            logsummary "$@" ;;
        *)
            if [[ -f "$mode" || "$mode" == "-" || "$mode" =~ \.(log|txt|gz|bz2|xz|zst)$ ]]; then
                logsummary "$@"
            else
                echo "logstats: unknown mode '$mode' (see logstats --help)" >&2
                return 1
            fi ;;
    esac
}

# If executed directly as a script (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    logstats "$@"
fi
