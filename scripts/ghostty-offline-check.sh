#!/usr/bin/env bash
#
# Proves that a cold rebuild of the pinned Ghostty works with the network off. It sets the current
# artifact aside, rebuilds from the kept source and the kept Zig package cache, and puts the
# artifact back if the rebuild fails or the script is interrupted. A dead proxy stands in for the
# network. The original artifact is only renamed, and it is deleted only after the rebuild succeeds.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-ghostty.sh"
CACHE="${GHOSTTY_CACHE_DIR:-$ROOT/.cache/ghostty}"

die() {
  echo "error: $*" >&2
  exit 1
}

# The kept caches must exist before they can be proven sufficient.
"$BUILD"
artifact="$("$BUILD" path)"
zig="$("$BUILD" zig)"

# shellcheck disable=SC1091
. "$ROOT/ghostty.pin"
tarball="$CACHE/dl/$GHOSTTY_COMMIT.tar.gz"
[ -f "$tarball" ] || die "the Ghostty source is not cached at $tarball."

mkdir -p "$CACHE/tmp"
scratch="$(mktemp -d "$CACHE/tmp/offline-check.XXXXXX")"
aside="$scratch/previous-artifact"
rebuilt=0

finish() {
  if [ ! -d "$artifact" ] && [ -d "$aside" ]; then
    mv "$aside" "$artifact"
    echo "Restored the previous artifact."
  fi
  if [ "$rebuilt" = "1" ] || [ ! -d "$aside" ]; then
    rm -rf "$scratch"
  fi
}
trap finish EXIT
trap 'exit 130' INT TERM

# Control: with an empty package cache and the dead proxy, Zig must fail to fetch a package. If it
# succeeds, the proxy does not cut the network and the check would prove nothing.
dependency_url="$(tar -xzOf "$tarball" "ghostty-$GHOSTTY_COMMIT/build.zig.zon" | grep -m1 -o 'https://[^"]*')"
[ -n "$dependency_url" ] || die "found no dependency URL in Ghostty's build.zig.zon."

if ZIG_GLOBAL_CACHE_DIR="$scratch/empty-zig-cache" \
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
  "$zig" fetch "$dependency_url" >/dev/null 2>&1; then
  die "Zig fetched a package through the dead proxy, so this check cannot prove the network is off."
fi
echo "Control passed: Zig cannot fetch packages through the dead proxy."

mv "$artifact" "$aside"

echo "Rebuilding the pinned Ghostty with the network off."
GHOSTTY_OFFLINE=1 "$BUILD" || die "the offline rebuild failed. The previous artifact is restored."

[ -d "$artifact/GhosttyKit.xcframework" ] || die "the offline rebuild left no xcframework."
rebuilt=1
echo "Offline rebuild succeeded: $(basename "$artifact")"
