#!/usr/bin/env bash
# Build herdr-pick and install the prebuilt binary beside the shim.
#
#   sesh/build-herdr-pick.sh          build + install sesh/bin/herdr-pick
#   sesh/build-herdr-pick.sh --clean  cargo clean first
#
# Offline first (the crate has a committed Cargo.lock and the deps are in the
# local cargo cache), network as a fallback.
set -euo pipefail

dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
crate="$dir/herdr-pick"

cd "$crate"
if [ "${1:-}" = "--clean" ]; then
    cargo clean
fi
if ! cargo build --release --offline; then
    echo "build-herdr-pick: offline build failed, retrying online" >&2
    cargo build --release
fi
mkdir -p "$dir/bin"
# copy then rename: overwriting the binary in place keeps its inode, and
# macOS then kills the new build on launch (stale code-signature cache)
cp target/release/herdr-pick "$dir/bin/herdr-pick.new"
mv -f "$dir/bin/herdr-pick.new" "$dir/bin/herdr-pick"
echo "installed $dir/bin/herdr-pick"
