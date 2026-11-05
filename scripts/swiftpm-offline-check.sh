#!/usr/bin/env bash
#
# Proves that the Swift packages resolve and build with the network off. The pinned versions come
# from the committed Package.resolved files, and the sources come from a kept package cache. A dead
# proxy stands in for the network.
#
# The check runs in four steps:
#   1. With the network on, it fills the kept cache from the committed Package.resolved. That
#      step is the only one that fetches.
#   2. A control resolves with an empty cache and the dead proxy, and must fail. If it succeeds,
#      the proxy does not cut the network and the check would prove nothing.
#   3. SwiftPM resolves into an empty scratch folder from the kept cache alone, then builds the
#      only target that uses a package, with automatic resolution off.
#   4. xcodebuild does the same resolve into empty clone and cache folders.
#
# Neither resolve may rewrite a Package.resolved. A changed pin is a failure, since it would mean
# the committed file did not name what the build used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/UnitermKit"
CACHE="${SWIFTPM_CACHE_DIR:-$ROOT/.cache/swiftpm}"
PACKAGE_PINS="$PACKAGE/Package.resolved"
WORKSPACE_PINS="$ROOT/uniterm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
DEAD_PROXY="http://127.0.0.1:9"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$PACKAGE_PINS" ] || die "$PACKAGE_PINS is missing. Commit the package's Package.resolved."
[ -f "$WORKSPACE_PINS" ] || die "$WORKSPACE_PINS is missing. Commit the workspace's Package.resolved."

mkdir -p "$CACHE"
work="$(mktemp -d "${TMPDIR:-/tmp}/uniterm-swiftpm-offline.XXXXXX")"
trap 'rm -rf "$work"' EXIT

without_network() {
  http_proxy="$DEAD_PROXY" https_proxy="$DEAD_PROXY" HTTP_PROXY="$DEAD_PROXY" \
    HTTPS_PROXY="$DEAD_PROXY" ALL_PROXY="$DEAD_PROXY" NO_PROXY="" no_proxy="" "$@"
}

package_pins_before="$(shasum -a 256 "$PACKAGE_PINS")"
workspace_pins_before="$(shasum -a 256 "$WORKSPACE_PINS")"

echo "Filling the kept package cache from the committed pins."
swift package --package-path "$PACKAGE" --scratch-path "$work/online" --cache-path "$CACHE/swiftpm" \
  --only-use-versions-from-resolved-file resolve

xcodebuild -resolvePackageDependencies -project "$ROOT/uniterm.xcodeproj" -scheme uniterm \
  -derivedDataPath "$work/online-derived" -clonedSourcePackagesDirPath "$work/online-clones" \
  -packageCachePath "$CACHE/xcode" -onlyUsePackageVersionsFromResolvedFile >/dev/null

if without_network swift package --package-path "$PACKAGE" --scratch-path "$work/control" \
  --cache-path "$work/control-cache" resolve >/dev/null 2>&1; then
  die "SwiftPM fetched a package through the dead proxy, so this check cannot prove the network is off."
fi

if without_network xcodebuild -resolvePackageDependencies -project "$ROOT/uniterm.xcodeproj" \
  -scheme uniterm -derivedDataPath "$work/control-derived" \
  -clonedSourcePackagesDirPath "$work/control-clones" -packageCachePath "$work/control-xcode-cache" \
  >/dev/null 2>&1; then
  die "xcodebuild fetched a package through the dead proxy, so this check cannot prove the network is off."
fi

echo "Control passed: neither SwiftPM nor xcodebuild can fetch a package through the dead proxy."

echo "Resolving and building with SwiftPM, network off."
without_network swift package --package-path "$PACKAGE" --scratch-path "$work/offline" \
  --cache-path "$CACHE/swiftpm" --only-use-versions-from-resolved-file resolve

[ -d "$work/offline/checkouts/ZIPFoundation" ] || die "the offline resolve left no ZIPFoundation checkout."

without_network swift build --package-path "$PACKAGE" --scratch-path "$work/offline" \
  --cache-path "$CACHE/swiftpm" --disable-automatic-resolution --target TableData

echo "Resolving with xcodebuild, network off."
without_network xcodebuild -resolvePackageDependencies -project "$ROOT/uniterm.xcodeproj" \
  -scheme uniterm -derivedDataPath "$work/offline-derived" \
  -clonedSourcePackagesDirPath "$work/offline-clones" -packageCachePath "$CACHE/xcode" \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution >/dev/null

[ -d "$work/offline-clones/checkouts/ZIPFoundation" ] ||
  die "the offline xcodebuild resolve left no ZIPFoundation checkout."

[ "$(shasum -a 256 "$PACKAGE_PINS")" = "$package_pins_before" ] ||
  die "a resolve rewrote $PACKAGE_PINS."
[ "$(shasum -a 256 "$WORKSPACE_PINS")" = "$workspace_pins_before" ] ||
  die "a resolve rewrote $WORKSPACE_PINS."

echo "Offline resolve and build succeeded from the committed pins."
