#!/usr/bin/env bash
# connect-herdr.sh — herdr prefix+w popup.
#
# The picker itself is now Rust (herdr-pick): one prebuilt binary, every
# string / command / style token in ../herdr-pick.json. This shim only execs
# it. If the binary has not been built yet it falls back to the old node
# picker / fzf backend so prefix+w never goes dead:
#
#   sesh/build-herdr-pick.sh     build + install sesh/bin/herdr-pick
#
# The old shell backend lives on as connect-herdr-fzf.sh for that fallback.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bin="${HERDR_PICK_BIN:-$here/bin/herdr-pick}"

if [ -x "$bin" ]; then
    exec "$bin" "$@"
fi

echo "connect-herdr: $bin not built; run $here/build-herdr-pick.sh" >&2
if [ "$#" -gt 0 ]; then
    exec "$here/connect-herdr-fzf.sh" "$@"
fi
if command -v node >/dev/null 2>&1; then
    exec node "$here/herdr-picker.mjs"
fi
exec "$here/connect-herdr-fzf.sh"
