#!/usr/bin/env bash
#
# launch.sh [--auto|--restart] — start ghostty-strip-bar, the AeroSpace workspace
# strip (native Rust panel pinned top-right of the Ghostty window).
#
#   launch.sh            start the bar unless it is already running
#   launch.sh --auto     same; used by AeroSpace's on-window-detected rule for Ghostty
#   launch.sh --restart  stop the running bar and start a fresh one (after a rebuild)
#
#   STRIP_BAR_HEIGHT=24  panel height in points
#
# The binary is built from ./bar on first use (cargo build --release); rebuild
# with:  (cd ~/.dotfiles/ghostty-strip/bar && cargo build --release) && launch.sh --restart

set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
bin="$dir/bar/target/release/ghostty-strip-bar"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

# one launcher at a time (the hook fires for every Ghostty window); drop a stale lock
lock="${TMPDIR:-/tmp}/ghostty-strip.lock"
find "$lock" -maxdepth 0 -mmin +2 -exec rmdir {} \; 2>/dev/null || true
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock"' EXIT

if [ "${1:-}" = "--restart" ]; then
    pkill -x ghostty-strip-bar 2>/dev/null || true
    sleep 0.3
fi

pgrep -x ghostty-strip-bar >/dev/null && exit 0

[ -x "$bin" ] || (cd "$dir/bar" && cargo build --release)

nohup "$bin" >/dev/null 2>&1 &
disown
