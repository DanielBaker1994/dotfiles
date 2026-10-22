# xtrace-summary.awk — self time per source line from timestamped `set -x` output.
#
# Expects PS4='+${EPOCHREALTIME}<TAB>${BASH_SOURCE[0]}:${LINENO}<TAB>${FUNCNAME[0]}<TAB>'
# (see the BASHPROF hook in bash/.bash_profile and herdr/plugins/prof.sh). The
# gap until the next trace line is charged to the line before it, so `eval
# "$(zoxide init bash)"` shows up as the cost of its line. Several files are
# allowed (one per run); each is timed on its own.
#
#   awk -v mode=lines -f xtrace-summary.awk FILE...  -> ms<TAB>runs<TAB>where<TAB>command
#   awk -v mode=files -f xtrace-summary.awk FILE...  -> ms<TAB>file
#   awk -v mode=total -f xtrace-summary.awk FILE...  -> ms<TAB>runs (traced wall time)
# Output is unsorted; pipe through `sort -t$'\t' -k1,1nr`.
#
# `where` is file:line, plus fn() when inside a function. Code run by eval
# (fzf --bash, starship init ...) reports line numbers of the eval'd text
# against the file that ran the eval; when that number is past the end of
# the file, `where` says "(eval)" so it isn't mistaken for a real line.

BEGIN { FS = "\t" }

FNR == 1 { finish(); files++ }

/^\++[0-9]+[.,][0-9]+\t/ {
    depth = match($1, /[^+]/) - 1
    ts = substr($1, depth + 1); sub(/,/, ".", ts); t = ts + 0
    if (have) charge(t - pt)
    else first = t
    have = 1; pt = t; pdepth = depth; pcmd = $4
    ploc = $2 (eval_line($2) ? " (eval)" : "") ($3 != "" ? " " $3 "()" : "")
    pfile = $2; sub(/:[0-9]+$/, "", pfile)
}

function charge(d) {
    self[ploc] += d; runs[ploc]++
    # show the outermost command run on that line (the eval, not its $(...))
    if (!(ploc in cmd) || pdepth < cdepth[ploc]) { cmd[ploc] = pcmd; cdepth[ploc] = pdepth }
    ftot[pfile] += d
}

# true when FILE:LINE points past the end of FILE
function eval_line(loc,   f, n, l) {
    f = loc; sub(/:[0-9]+$/, "", f)
    n = loc; sub(/^.*:/, "", n)
    if (!(f in len)) {
        len[f] = 0
        while ((getline l < f) > 0) len[f]++
        close(f)
        if (len[f] == 0) len[f] = 1e9   # unreadable: don't guess
    }
    return n + 0 > len[f]
}

function finish() {
    if (have) total += pt - first
    have = 0
}

END {
    finish()
    if (mode == "files") for (f in ftot) printf "%.1f\t%s\n", ftot[f] * 1000, f
    else if (mode == "total") printf "%.1f\t%d\n", total * 1000, files
    else for (l in self) printf "%.1f\t%d\t%s\t%s\n", self[l] * 1000, runs[l], l, substr(cmd[l], 1, 80)
}
