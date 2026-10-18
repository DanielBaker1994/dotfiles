#!/usr/bin/env bash
# connect-herdr.sh — herdr prefix+w popup launcher.
#
# The picker is the Rust binary below (sesh/bin/herdr-pick): one prebuilt
# binary, every string / command / style token in herdr-pick.json. There is
# deliberately no node / fzf fallback anymore — if the binary is missing the
# shim builds it once, and if even that can't work it draws an elegant error
# instead of letting prefix+w go dead:
#
#   workspace_setup.sh                 links herdr plugins + builds the picker
#   sesh/build-herdr-pick.sh           build + install sesh/bin/herdr-pick
#
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bin="${HERDR_PICK_BIN:-$here/bin/herdr-pick}"
log="${TMPDIR:-/tmp}/herdr-pick-build.log"

# one quiet build attempt when the binary isn't there (HERDR_PICK_NO_BUILD=1
# skips it — used to preview the error path)
if [ ! -x "$bin" ] && [ "${HERDR_PICK_NO_BUILD:-0}" != "1" ]; then
    printf 'herdr-pick: first run — building the picker, one moment…\n'
    if command -v cargo >/dev/null 2>&1; then
        "$here/build-herdr-pick.sh" >"$log" 2>&1 || true
    else
        : >"$log"
    fi
fi

if [ -x "$bin" ]; then
    exec "$bin" "$@"
fi

# ── elegant error (no fallback by design) ───────────────────────────────────
R=$'\033[38;2;201;79;109m'    # danger  #C94F6D
A=$'\033[38;2;113;156;214m'   # accent  #719CD6
T=$'\033[38;2;205;206;207m'   # text    #CDCECF
D=$'\033[38;2;174;175;176m'   # dim     #AEAFB0
N=$'\033[0m'

if [ "${HERDR_PICK_NO_BUILD:-0}" = "1" ]; then
    why="the build was skipped (HERDR_PICK_NO_BUILD=1)"
elif ! command -v cargo >/dev/null 2>&1; then
    why="cargo is not installed — brew install rust"
elif [ -s "$log" ]; then
    why="the build failed — cargo's last lines below"
else
    why="the build could not run"
fi

W=68
row() {
    local s="${1:0:$W}"
    printf '%s│%s %s%*s %s│%s\n' "$R" "$2" "$s" "$((W - ${#s}))" '' "$R" "$N"
}
bar() {
    local g e i dashes=""
    [ "$1" = top ] && { g='╭'; e='╮'; } || { g='╰'; e='╯'; }
    for ((i = 0; i < W + 2; i++)); do dashes+="─"; done
    printf '%s%s%s%s%s\n' "$R" "$g" "$dashes" "$e" "$N"
}

bar top
row "herdr-pick — prefix+w can't start" "$A"
row "" "$T"
row "  $why" "$T"
row "  binary: ${bin/$HOME/\~}" "$D"
if [ -n "${HERDR_PICK_BIN:-}" ]; then
    row "  (from HERDR_PICK_BIN; default: ${here/$HOME/\~}/bin/herdr-pick)" "$D"
fi
if [ -s "$log" ]; then
    row "  ── build log (last lines) ──" "$D"
    while IFS= read -r l; do
        row "  ${l:0:$((W - 2))}" "$D"
    done < <(tail -3 "$log")
fi
row "" "$T"
row "  fix it with either of:" "$T"
row "    ~/.dotfiles/workspace_setup.sh" "$A"
row "    ~/.dotfiles/sesh/build-herdr-pick.sh" "$A"
row "" "$T"
row "  press any key" "$D"
bar bot

if [ -t 0 ]; then
    read -rsn1 -t 30 || true
else
    sleep 2
fi
exit 1
