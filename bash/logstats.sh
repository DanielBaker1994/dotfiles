#!/usr/bin/env bash
# logstats.sh — heavy log-file intelligence module for cpp_debug.sh.
#
# Provides: logfilestats, logaround, latency  (see dhelp in cpp_debug.sh)
#
# Deploy alongside the core kit:
#   scp cpp_debug.sh logstats.sh user@host:
#   source ~/cpp_debug.sh          # auto-loads this file if it sits next to it
#
# Design notes:
# * FORMAT SNIFFING: the timestamp format is detected once from the first
#   400 lines (_ls_sniff), then a format-specialized parser runs per line —
#   no re-trying of every alternative regex on every line of a 5GB file.
# * SINGLE PASS: logfilestats computes gaps AND template frequencies in one
#   read of the file (halves NAS I/O vs separate passes).
# * LC_ALL=C everywhere: byte-wise parsing survives binary garbage in logs
#   (and is much faster than multibyte locales).
# * COMPRESSION: _lgz_cat dispatches on extension: plain, .gz, .bz2, .xz,
#   .zst (zstd tool permitting).
#
# Supported timestamp formats:
#   iso      2026-08-23T14:01:02.123 / 2026-08-23 14:01:02 (comma decimal ok,
#            trailing Z or +02:00 ignored)
#   slash    2026-08-23 14:01:02 (Windows/IIS style)
#   syslog   Aug 23 14:01:02 (line start, current year assumed)
#   clf      23/Aug/2026:14:01:02 (apache/nginx access log; tz offset ignored)
#   apache   [Sun Aug 23 14:01:02 2026] (apache error log)
#   hdfs     081109 203615 (yymmdd hhmmss compact, 2000+yy assumed)
#   epoch    1724418062 or 1724418062123 as the FIRST token (sec / ms)
# Requires: bash >= 4.2, awk (any POSIX), sort/uniq/cut/wc/head, gzip.

# ---------------------------------------------------------------------------
# reader: dispatch on extension so .gz/.bz2/.xz/.zst all work
# ---------------------------------------------------------------------------
_lgz_cat() {
    case "$1" in
        *.gz|*.Z)
            command -v gzip >/dev/null 2>&1 || { echo "logstats: gzip missing" >&2; return 1; }
            gzip -dc -- "$1" ;;
        *.bz2)
            command -v bzip2 >/dev/null 2>&1 || { echo "logstats: bzip2 missing" >&2; return 1; }
            bzip2 -dc -- "$1" ;;
        *.xz)
            command -v xz >/dev/null 2>&1 || { echo "logstats: xz missing" >&2; return 1; }
            xz -dc -- "$1" ;;
        *.zst|*.zstd)
            command -v zstd >/dev/null 2>&1 || { echo "logstats: zstd missing" >&2; return 1; }
            zstd -dc -- "$1" ;;
        *)
            cat -- "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# shared awk library (interpolated at the start of every awk program below)
# ---------------------------------------------------------------------------
# ts_parse(line) — parse a timestamp using the sniffed format (var fmt).
# Sets G_E (epoch seconds), G_SHOW (display string), G_S/G_L (match
# position/length in the line, for stripping). Returns 1 on success.
_LS_LIB='
function d2e(y, m, d, H, M, S,    era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + H * 3600 + M * 60 + S
}
function mon_init(    i, n, mn) {
    n = split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= n; i++) MON[mn[i]] = i
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
function skel(x) {
    gsub(/0[xX][0-9a-fA-F]+/, "0xN", x)
    gsub(/[0-9]+/, "N", x)
    return x
}
function ts_parse(line,    ts, frac, a, t2, tok, L, w) {
    if (fmt == "epoch") {
        split(line, w, /[ \t]+/)
        tok = w[1]
        L = length(tok)
        if ((L != 10 && L != 13) || tok !~ /^[0-9]+$/) return 0
        G_E = tok + 0
        if (L == 13) G_E = G_E / 1000
        G_SHOW = tok
        match(line, /^[ \t]*/)
        G_S = RLENGTH + 1
        G_L = L
        return 1
    }
    if (fmt == "iso") {
        if (!match(line, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.,][0-9]+)?/)) return 0
    } else if (fmt == "slash") {
        if (!match(line, /[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.,][0-9]+)?/)) return 0
    } else if (fmt == "clf") {
        if (!match(line, /[0-9][0-9]\/[A-Z][a-z][a-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return 0
    } else if (fmt == "apache") {
        if (!match(line, /\[[A-Z][a-z][a-z] [A-Z][a-z][a-z] +[0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9]\]/)) return 0
    } else if (fmt == "syslog") {
        if (!match(line, /^[A-Z][a-z][a-z] +[0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return 0
    } else if (fmt == "hdfs") {
        if (!match(line, /^[0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9][0-9][0-9]/)) return 0
    } else return 0
    ts = substr(line, RSTART, RLENGTH)
    G_S = RSTART; G_L = RLENGTH
    G_SHOW = ts
    frac = 0
    if (fmt == "iso" || fmt == "slash") {
        sub(/T/, " ", G_SHOW)
        if (match(ts, /[.,][0-9]+$/)) {
            frac = ("0." substr(ts, RSTART + 1, RLENGTH - 1)) + 0
            ts = substr(ts, 1, RSTART - 1)
        }
        split(ts, a, /[-\/ :]/)
        G_E = d2e(a[1] + 0, a[2] + 0, a[3] + 0, a[4] + 0, a[5] + 0, a[6] + 0) + frac
    } else if (fmt == "clf") {
        split(ts, a, /[\/:]/)
        if (!(a[2] in MON)) return 0
        G_E = d2e(a[3] + 0, MON[a[2]], a[1] + 0, a[4] + 0, a[5] + 0, a[6] + 0)
    } else if (fmt == "apache") {
        gsub(/[\[\]]/, "", ts)
        gsub(/ +/, " ", ts)
        split(ts, a, " ")
        if (!(a[2] in MON)) return 0
        split(a[4], t2, ":")
        G_E = d2e(a[5] + 0, MON[a[2]], a[3] + 0, t2[1] + 0, t2[2] + 0, t2[3] + 0)
    } else if (fmt == "syslog") {
        gsub(/ +/, " ", ts)
        split(ts, a, " ")
        if (!(a[1] in MON)) return 0
        split(a[3], t2, ":")
        G_E = d2e(yr, MON[a[1]], a[2] + 0, t2[1] + 0, t2[2] + 0, t2[3] + 0)
    } else if (fmt == "hdfs") {
        split(ts, a, " ")
        if (substr(a[1], 3, 2) + 0 < 1 || substr(a[1], 3, 2) + 0 > 12) return 0
        if (substr(a[2], 1, 2) + 0 > 23 || substr(a[2], 3, 2) + 0 > 59 || substr(a[2], 5, 2) + 0 > 59) return 0
        G_E = d2e(2000 + substr(a[1], 1, 2), substr(a[1], 3, 2) + 0, substr(a[1], 5, 2) + 0, \
                  substr(a[2], 1, 2) + 0, substr(a[2], 3, 2) + 0, substr(a[2], 5, 2) + 0)
        G_SHOW = "20" substr(a[1], 1, 2) "-" substr(a[1], 3, 2) "-" substr(a[1], 5, 2) " " \
                 substr(a[2], 1, 2) ":" substr(a[2], 3, 2) ":" substr(a[2], 5, 2)
    }
    return 1
}
'

# _ls_sniff FILE — detect the timestamp format from the first 400 lines.
# Echoes one of: iso slash clf apache syslog hdfs epoch none
_ls_sniff() {
    _lgz_cat "$1" 2>/dev/null | head -n 400 | LC_ALL=C awk '
        {
            if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) iso++
            else if (match($0, /[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) slash++
            else if (match($0, /[0-9][0-9]\/[A-Z][a-z][a-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) clf++
            else if (match($0, /\[[A-Z][a-z][a-z] [A-Z][a-z][a-z] +[0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9]\]/)) apache++
            else if (match($0, /^[A-Z][a-z][a-z] +[0-9][0-9]? [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) syslog++
            else if (match($0, /^[0-9][0-9][0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9][0-9][0-9]/)) hdfs++
            else {
                split($0, w, /[ \t]+/)
                L = length(w[1])
                if ((L == 10 || L == 13) && w[1] ~ /^[0-9]+$/) epoch++
            }
        }
        END {
            best = "none"; bc = 0
            if (iso > bc)    { bc = iso;    best = "iso" }
            if (slash > bc)  { bc = slash;  best = "slash" }
            if (clf > bc)    { bc = clf;    best = "clf" }
            if (apache > bc) { bc = apache; best = "apache" }
            if (syslog > bc) { bc = syslog; best = "syslog" }
            if (hdfs > bc)   { bc = hdfs;   best = "hdfs" }
            if (epoch > bc)  { bc = epoch;  best = "epoch" }
            if (bc < 5) best = "none"
            print best
        }'
}

# ---------------------------------------------------------------------------
# logfilestats — overview + longest silences + frequent templates, ONE pass
# ---------------------------------------------------------------------------
# logfilestats FILE [RANGE=1:-1] [TOPN=10]
# (0) run overview: first + last timestamped line, duration in h/m/s
# (1) TOPN longest silences between consecutive timestamped lines
# (2) most frequent line templates (timestamps removed, digit runs -> N);
#     timestamp-less lines skipped and counted; json/xml/kv payloads get
#     their own table. RANGE is slice style, negatives from the end:
#     100:-1 starts at line 100, "100:" same, ":500" first 500, "-500:" last.
logfilestats() {
    if [[ $# -eq 0 || "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
        cat <<'EOF'
usage: logfilestats FILE [RANGE=1:-1] [TOPN=10]
  overview (first/last line + duration) + longest silences + line templates
  RANGE: slice style, 1-based; negatives count from the end (like python)
         100:-1  start at line 100 (drops 99 startup lines)   100:  same
         :500    first 500 lines only                          -500:  last 500
  timestamp format is auto-detected (iso, slash, syslog, clf, apache, hdfs,
  epoch); templates: timestamps removed, digit runs -> N, 0x.. -> 0xN
  json/xml/kv payload lines are auto-detected and get their own table
EOF
        if [[ $# -eq 0 ]]; then return 1; fi
        return 0
    fi
    local file="$1" range="${2:-1:-1}" topn="${3:-10}"
    [[ -r "$file" ]] || { echo "logfilestats: cannot read $file" >&2; return 1; }
    if ! [[ "$topn" =~ ^[0-9]+$ ]] || ((topn < 1)); then
        echo "logfilestats: TOPN must be a number >= 1" >&2
        return 1
    fi
    local start end
    if [[ "$range" =~ ^(-?[0-9]*):(-?[0-9]*)$ ]]; then
        start="${BASH_REMATCH[1]:-1}"
        end="${BASH_REMATCH[2]:--1}"
    else
        echo "logfilestats: bad RANGE '$range' (want e.g. 100:-1, 100:, :500)" >&2
        return 1
    fi
    if ((start == 0 || end == 0)); then
        echo "logfilestats: RANGE is 1-based; 0 is not a valid line number" >&2
        return 1
    fi
    if ((start < 0 || end < 0)); then
        local total
        total=$(_lgz_cat "$file" | wc -l)
        ((start < 0)) && start=$((total + start + 1))
        ((end < 0)) && end=$((total + end + 1))
    fi
    ((start < 1)) && start=1
    if ((end < start)); then
        echo "logfilestats: RANGE resolves to an empty window" >&2
        return 1
    fi

    local fmt
    fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logfilestats: no recognizable timestamp format in first 400 lines" >&2
        echo "supported: iso, slash (yyyy/mm/dd), syslog, clf, apache, hdfs, epoch" >&2
        return 1
    fi

    echo "--- logfilestats: $file (lines $start..$end, top $topn, format: $fmt)"

    local tmp_p tmp_s
    tmp_p=$(mktemp) || return 1
    tmp_s=$(mktemp) || { rm -f "$tmp_p"; return 1; }

    # THE single pass: gaps tracked in memory, skeletons streamed to temp
    # files for the external sort/uniq frequency tables.
    _lgz_cat "$file" | LC_ALL=C awk -v fmt="$fmt" -v yr="$(date +%Y)" \
        -v start="$start" -v end="$end" -v topn="$topn" \
        -v pf="$tmp_p" -v sf="$tmp_s" "$_LS_LIB"'
        function ins(gap, ln1, ln2, t1, t2, content,    i) {
            if (gap <= gaps[topn]) return
            i = topn
            while (i > 1 && gap > gaps[i - 1]) {
                gaps[i] = gaps[i-1]; gf[i] = gf[i-1]; gt[i] = gt[i-1]
                g1[i] = g1[i-1]; g2[i] = g2[i-1]; gl[i] = gl[i-1]
                i--
            }
            gaps[i] = gap; gf[i] = ln1; gt[i] = ln2
            g1[i] = t1; g2[i] = t2; gl[i] = content
            if (seen < topn) seen++
        }
        BEGIN { mon_init(); for (i = 1; i <= topn; i++) gaps[i] = -1 }
        NR < start || NR > end { next }
        {
            lines++
            if (!ts_parse($0)) { nots++; next }
            e = G_E
            if (have) {
                d = e - pe
                if (d < 0) neg++
                else ins(d, pnr, NR, pts, G_SHOW, substr($0, 1, 100))
            } else {
                first = e
                firstnr = NR; firstline = substr($0, 1, 100)
            }
            pe = e; pnr = NR; pts = G_SHOW; have = 1
            nts++; last = e
            lastnr = NR; lastline = substr($0, 1, 100)

            s = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
            sub(/^[ \t]+/, "", s)
            if (s != "") {
                c1 = s; kv = gsub(/[A-Za-z_][A-Za-z0-9_.]*=/, "&", c1)
                c2 = s; dr = gsub(/[0-9]+/, "&", c2)
                sk = skel(s)
                if (s ~ /^[[{<]/ || kv >= 3 || dr >= 6) print sk > sf
                else                                   print sk > pf
            }
        }
        END {
            if (!have) {
                printf "lines in window: %d — no timestamped lines found\n", lines
                exit
            }
            printf "first: L%-8d %s\n", firstnr, firstline
            printf "last:  L%-8d %s\n", lastnr, lastline
            printf "duration: %s\n", hms(last - first)
            print ""
            printf "lines in window: %d  (timestamped: %d, without timestamp: %d)\n", lines, nts, nots
            if (nts < 2) { print "not enough timestamped lines to measure gaps"; exit }
            printf "avg gap between lines: %.3fs   negative time jumps: %d%s\n", \
                (last - first) / (nts - 1), neg, \
                (neg > 0 ? "  (not chronological? logsort first)" : "")
            print ""
            print "longest silences between log lines:"
            for (i = 1; i <= seen; i++)
                printf "%3d. %10s   line %d -> line %d\n     %s -> %s\n     wakes with: %s\n", \
                    i, hum(gaps[i]), gf[i], gt[i], g1[i], g2[i], gl[i]
            print ""
            print "--- most frequent line templates (timestamps removed, digits -> N)"
            if (nots > 0)
                printf "(skipped %d timestamp-less lines — not from the standard logger)\n", nots
        }'

    local fmt_awk='{ c = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if (length($0) > 110) $0 = substr($0, 1, 110) "..."
                printf "%8d  %s\n", c, $0 }'
    if [[ -s "$tmp_p" ]]; then
        echo "plain log lines:"
        LC_ALL=C sort "$tmp_p" | uniq -c | LC_ALL=C sort -rn | head -n "$topn" | awk "$fmt_awk"
    else
        echo "plain log lines: (none)"
    fi
    if [[ -s "$tmp_s" ]]; then
        echo "structured payloads (json/xml/kv — auto-detected, counted separately):"
        LC_ALL=C sort "$tmp_s" | uniq -c | LC_ALL=C sort -rn | head -n "$topn" | awk "$fmt_awk"
    fi
    rm -f "$tmp_p" "$tmp_s"
}

# ---------------------------------------------------------------------------
# logaround — time-based context around matches (two passes, unavoidable:
# the window extends into the future of each match)
# ---------------------------------------------------------------------------
logaround() {
    if [[ $# -lt 2 || "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
        cat <<'EOF'
usage: logaround FILE PATTERN [SECS=5]
  every line within ±SECS seconds of each PATTERN match (ERE)
  overlapping windows merge; matched lines prefixed >>; clusters separated
  timestamp format auto-detected; assumes chronological input (logsort first)
EOF
        if [[ $# -lt 2 ]]; then return 1; fi
        return 0
    fi
    local file="$1" pat="$2" secs="${3:-5}"
    [[ -r "$file" ]] || { echo "logaround: cannot read $file" >&2; return 1; }
    if ! [[ "$secs" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo "logaround: SECS must be a number, got '$secs'" >&2
        return 1
    fi
    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    if [[ $? -eq 2 ]]; then
        echo "logaround: invalid pattern '$pat'" >&2
        return 1
    fi
    local fmt
    fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "logaround: no recognizable timestamp format in first 400 lines" >&2
        return 1
    fi

    # pass 1: merged [lo,hi] windows around every match timestamp
    local ivs
    ivs=$(_lgz_cat "$file" | LC_ALL=C awk -v fmt="$fmt" -v yr="$(date +%Y)" \
        -v pat="$pat" -v secs="$secs" "$_LS_LIB"'
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
        echo "logaround: no timestamped matches for '$pat'" >&2
        return 1
    fi
    ivs=${ivs//$'\n'/|}    # awk -v cannot carry newlines; fields split on |

    # pass 2: print lines inside any window
    _lgz_cat "$file" | LC_ALL=C awk -v fmt="$fmt" -v yr="$(date +%Y)" \
        -v ivss="$ivs" -v pat="$pat" -v secs="$secs" "$_LS_LIB"'
        BEGIN {
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
}

# ---------------------------------------------------------------------------
# latency — percentiles of numbers extracted from matching lines
# ---------------------------------------------------------------------------
latency() {
    if [[ $# -lt 1 || "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
        cat <<'EOF'
usage: latency FILE MATCHRE [UNIT=m|h|s]
  percentiles of the first number (after the timestamp) on each line
  matching MATCHRE; overall + per-bucket, worst 10 buckets by p99
  timestamp format auto-detected; epoch logs bucket in local time
  example: latency api.log 'took [0-9.]+ ms'
EOF
        if [[ $# -lt 1 ]]; then return 1; fi
        return 0
    fi
    local file="${1:?usage: latency FILE MATCHRE [UNIT=m|h|s]}" pat="${2:?usage: latency FILE MATCHRE [UNIT=m|h|s]}"
    local unit="${3:-m}" unitdesc
    [[ -r "$file" ]] || { echo "latency: cannot read $file" >&2; return 1; }
    case "$unit" in
        m) unitdesc=minute ;;
        h) unitdesc=hour ;;
        s) unitdesc=second ;;
        *) echo "latency: UNIT must be m, h or s" >&2; return 1 ;;
    esac
    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    if [[ $? -eq 2 ]]; then
        echo "latency: invalid pattern '$pat'" >&2
        return 1
    fi
    local fmt
    fmt=$(_ls_sniff "$file")
    if [[ -z "$fmt" || "$fmt" == "none" ]]; then
        echo "latency: no recognizable timestamp format in first 400 lines" >&2
        return 1
    fi
    # local timezone offset (only applied to epoch-format logs, whose
    # timestamps are true UTC; wall-clock formats are already local)
    local zs tzo=0
    zs=$(date +%z 2>/dev/null)
    if [[ "$zs" =~ ^([+-])([0-9][0-9])([0-9][0-9])$ ]]; then
        tzo=$((10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60))
        [[ "${BASH_REMATCH[1]}" == "-" ]] && tzo=$((-tzo))
    fi

    local tmp tmpv tmpb
    tmp=$(mktemp) || return 1
    tmpv=$(mktemp) || { rm -f "$tmp"; return 1; }
    tmpb=$(mktemp) || { rm -f "$tmp" "$tmpv"; return 1; }

    _lgz_cat "$file" | LC_ALL=C awk -v fmt="$fmt" -v yr="$(date +%Y)" \
        -v pat="$pat" -v unit="$unit" -v tzo="$tzo" "$_LS_LIB"'
        function e2b(e, off,    z, era, doe, yoe, y, doy, mp, dd, mm, rem, hh, mi) {
            e += off
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
            hh = int(rem / 3600); mi = int((rem % 3600) / 60)
            if (unit == "h") return sprintf("%04d-%02d-%02d %02d", y, mm, dd, hh)
            if (unit == "s") return sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, mm, dd, hh, mi, int(rem % 60))
            return sprintf("%04d-%02d-%02d %02d:%02d", y, mm, dd, hh, mi)
        }
        BEGIN { mon_init() }
        {
            if (!ts_parse($0)) next
            rest = substr($0, 1, G_S - 1) substr($0, G_S + G_L)
            if (rest !~ pat) next
            if (match(rest, /[0-9]+(\.[0-9]+)?/))
                printf "%s\t%s\n", e2b(G_E, (fmt == "epoch" ? tzo : 0)), substr(rest, RSTART, RLENGTH)
        }' | LC_ALL=C sort -t $'\t' -k1,1 -k2,2g > "$tmp"
    if [[ ! -s "$tmp" ]]; then
        echo "latency: no samples (nothing matching '$pat' with a number)" >&2
        rm -f "$tmp" "$tmpv" "$tmpb"
        return 1
    fi

    echo "--- latency: $file (format: $fmt)"
    echo "pattern: $pat   (first number after the timestamp on each matching line)"

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
            printf "samples: %d\n", n
            printf "overall: min %.3f | p50 %.3f | p90 %.3f | p95 %.3f | p99 %.3f | max %.3f | avg %.3f\n", \
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
            printf "%s\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n", cur, cnt, vals[1], pi(50), pi(95), pi(99), vals[cnt]
            split("", vals)
            cnt = 0
        }
        $1 != cur { flush(); cur = $1 }
        { vals[++cnt] = $2 + 0 }
        END { flush() }' "$tmp" > "$tmpb"

    local fmt_out='{ printf "%s  n=%-6d min %10.3f  p50 %10.3f  p95 %10.3f  p99 %10.3f  max %10.3f\n", $1, $2, $3, $4, $5, $6, $7 }'
    echo
    echo "--- worst 10 ${unitdesc}s by p99:"
    LC_ALL=C sort -t $'\t' -k6,6gr "$tmpb" | head -n 10 | awk -F '\t' "$fmt_out"
    echo
    echo "--- per-${unitdesc} table (chronological):"
    awk -F '\t' "$fmt_out" "$tmpb"

    rm -f "$tmp" "$tmpv" "$tmpb"
}
