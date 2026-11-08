#!/usr/bin/env bash
#
# Builds GhosttyKit.xcframework and Ghostty's resources from the commit pinned in ghostty.pin.
#
# Usage:
#   scripts/build-ghostty.sh          build the pinned artifact when it is missing, then link it
#   scripts/build-ghostty.sh verify   check that the linked artifact matches the pin and the toolchain
#   scripts/build-ghostty.sh path     print the directory of the artifact for the current pin
#   scripts/build-ghostty.sh tree-hash  print the source tree hash for GHOSTTY_COMMIT
#   scripts/build-ghostty.sh zig      print the path of the pinned Zig, downloading it when missing
#
# Bumping the pin: set GHOSTTY_TAG and GHOSTTY_COMMIT in ghostty.pin, run `tree-hash` and record its
# output as GHOSTTY_TREE_SHA256, then update the toolchain fields. A build fails when the extracted
# source does not hash to GHOSTTY_TREE_SHA256.
#
# Layout under $GHOSTTY_CACHE_DIR (default .cache/ghostty in the repo):
#   dl/<commit>.tar.gz     the Ghostty source for the pinned commit
#   zig/<version>/         the pinned Zig, downloaded from ziglang.org and checked against ZIG_SHA256
#   zig-global/            Zig's global package cache, kept so a cold rebuild needs no network
#   artifacts/<key>/       finished artifacts. A directory appears here only by an atomic rename.
#   tmp/                   scratch space for builds in progress
#   lock/                  held while a build runs, so concurrent builds serialize
#
# The key is the Ghostty commit, the Zig version, and the Xcode and SDK versions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${GHOSTTY_PIN_FILE:-$ROOT/ghostty.pin}"
CACHE="${GHOSTTY_CACHE_DIR:-$ROOT/.cache/ghostty}"
LINK_DIR="${GHOSTTY_LINK_DIR:-$ROOT/Packages/UnitermKit/Frameworks}"
OFFLINE="${GHOSTTY_OFFLINE:-0}"
LOCK_WAIT_SECONDS="${GHOSTTY_LOCK_WAIT_SECONDS:-1800}"

die() {
  echo "error: $*" >&2
  exit 1
}

read_pin() {
  [ -f "$PIN_FILE" ] || die "pin file not found: $PIN_FILE"
  GHOSTTY_TAG="" GHOSTTY_COMMIT="" ZIG_VERSION="" ZIG_SHA256="" XCODE_VERSION="" XCODE_BUILD=""
  SDK_VERSION=""
  # shellcheck disable=SC1090
  . "$PIN_FILE"
  for name in GHOSTTY_TAG GHOSTTY_COMMIT ZIG_VERSION ZIG_SHA256 XCODE_VERSION XCODE_BUILD SDK_VERSION; do
    [ -n "${!name}" ] || die "$PIN_FILE does not set $name"
  done
}

read_toolchain() {
  local xcode_out
  xcode_out="$(xcodebuild -version 2>/dev/null)" || die "xcodebuild -version failed. Select Xcode $XCODE_VERSION."
  INSTALLED_XCODE_VERSION="$(printf '%s\n' "$xcode_out" | awk '/^Xcode/ { print $2 }')"
  INSTALLED_XCODE_BUILD="$(printf '%s\n' "$xcode_out" | awk '/^Build version/ { print $3 }')"
  INSTALLED_SDK_VERSION="$(xcrun -sdk macosx --show-sdk-version 2>/dev/null)" ||
    die "xcrun could not report the macOS SDK version."
}

# Xcode and the SDK must match what the pin was built with.
check_toolchain() {
  if [ "$INSTALLED_XCODE_BUILD" != "$XCODE_BUILD" ] || [ "$INSTALLED_SDK_VERSION" != "$SDK_VERSION" ]; then
    die "ghostty.pin was built with Xcode $XCODE_VERSION ($XCODE_BUILD) and SDK $SDK_VERSION. Installed: Xcode $INSTALLED_XCODE_VERSION ($INSTALLED_XCODE_BUILD), SDK $INSTALLED_SDK_VERSION. Select Xcode $XCODE_VERSION, or bump ghostty.pin together with a Ghostty pin bump."
  fi
}

# Zig is needed only to build. The build uses the Zig that ghostty.pin names, from the cache, and
# never one on PATH. Callers hold the build lock, so two builds never unpack Zig into one place.
ensure_zig() {
  ZIG_HOME="$CACHE/zig/$ZIG_VERSION"
  ZIG="$ZIG_HOME/zig"

  if [ ! -x "$ZIG" ]; then
    [ "$(uname -m)" = "arm64" ] ||
      die "ghostty.pin names the aarch64 macOS build of Zig, and this machine is $(uname -m)."
    [ "$OFFLINE" = "1" ] && die "GHOSTTY_OFFLINE=1, and Zig $ZIG_VERSION is not cached in $CACHE/zig."

    local archive="zig-aarch64-macos-$ZIG_VERSION.tar.xz"
    mkdir -p "$CACHE/zig" "$CACHE/tmp"
    local scratch
    scratch="$(mktemp -d "$CACHE/tmp/zig.XXXXXX")"

    echo "Fetching Zig $ZIG_VERSION."
    if ! curl --fail --silent --show-error --location --output "$scratch/$archive" \
      "https://ziglang.org/download/$ZIG_VERSION/$archive"; then
      rm -rf "$scratch"
      die "could not download Zig $ZIG_VERSION."
    fi

    if ! echo "$ZIG_SHA256  $scratch/$archive" | shasum -a 256 --check --status; then
      rm -rf "$scratch"
      die "the Zig $ZIG_VERSION download does not match ZIG_SHA256 in ghostty.pin."
    fi

    tar -xJf "$scratch/$archive" -C "$scratch" || {
      rm -rf "$scratch"
      die "could not unpack Zig $ZIG_VERSION."
    }

    # The rename is the commit point, so a directory under zig/ is always a complete Zig.
    rm -rf "$ZIG_HOME"
    mv "$scratch/zig-aarch64-macos-$ZIG_VERSION" "$ZIG_HOME"
    rm -rf "$scratch"
  fi

  local version
  version="$("$ZIG" version)" || die "$ZIG does not run."
  [ "$version" = "$ZIG_VERSION" ] ||
    die "$ZIG reports version $version, but ghostty.pin requires $ZIG_VERSION."
}

compute_key() {
  KEY="${GHOSTTY_COMMIT:0:12}-zig${ZIG_VERSION}-xcode${XCODE_BUILD}-sdk${SDK_VERSION}"
  ARTIFACT="$CACHE/artifacts/$KEY"
}

manifest_value() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# The manifest must agree with the pin and with the installed toolchain.
check_manifest() {
  local manifest="$ARTIFACT/manifest"
  [ -f "$manifest" ] || die "artifact $KEY has no manifest. Run make build."

  local expected_pairs=(
    "GHOSTTY_COMMIT=$GHOSTTY_COMMIT"
    "ZIG_VERSION=$ZIG_VERSION"
    "XCODE_VERSION=$XCODE_VERSION"
    "XCODE_BUILD=$XCODE_BUILD"
    "SDK_VERSION=$SDK_VERSION"
  )
  local pair name want got
  for pair in "${expected_pairs[@]}"; do
    name="${pair%%=*}"
    want="${pair#*=}"
    got="$(manifest_value "$manifest" "$name")"
    if [ "$got" != "$want" ]; then
      die "libghostty manifest records $name=$got, but the pin and toolchain say $want. The artifact was built with Xcode $(manifest_value "$manifest" XCODE_VERSION) ($(manifest_value "$manifest" XCODE_BUILD)). Run make build."
    fi
  done

  [ -d "$ARTIFACT/GhosttyKit.xcframework" ] || die "artifact $KEY has no GhosttyKit.xcframework. Run make build."
  [ -d "$ARTIFACT/share/ghostty" ] || die "artifact $KEY has no shell-integration resources. Run make build."
  [ -d "$ARTIFACT/share/terminfo" ] || die "artifact $KEY has no terminfo. Run make build."
}

link_artifact() {
  mkdir -p "$LINK_DIR"
  ln -sfn "$ARTIFACT/GhosttyKit.xcframework" "$LINK_DIR/GhosttyKit.xcframework"
  ln -sfn "$ARTIFACT/share" "$LINK_DIR/GhosttyResources"
}

# The lock is a flock on an open file descriptor. The kernel drops it when the last process holding
# the descriptor exits, even after kill -9, so there is no stale lock to take over. Build children
# inherit the descriptor, which keeps the lock while any of them still runs.
acquire_lock() {
  mkdir -p "$CACHE"
  exec 9>"$CACHE/build.lock"
  python3 -c '
import fcntl, sys, time
deadline = time.monotonic() + float(sys.argv[1])
announced = False
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            print("error: timed out waiting for another Ghostty build to finish.", file=sys.stderr)
            sys.exit(1)
        if not announced:
            print("Waiting for another Ghostty build to finish.")
            announced = True
        time.sleep(1)
' "$LOCK_WAIT_SECONDS"
}

WORK=""

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}

# Leftovers from builds that were killed. Only called while holding the build lock, so no live
# build owns them.
remove_stale_work() {
  local stale
  for stale in "$CACHE"/tmp/build.* "$CACHE"/tmp/zig.*; do
    [ -d "$stale" ] || continue
    echo "Removing leftover build directory $(basename "$stale")."
    rm -rf "$stale"
  done
}

FETCHED=0

fetch_source() {
  local tarball="$CACHE/dl/$GHOSTTY_COMMIT.tar.gz"
  [ -f "$tarball" ] && return 0
  [ "$OFFLINE" = "1" ] && die "GHOSTTY_OFFLINE=1, and the Ghostty source for $GHOSTTY_COMMIT is not cached."

  mkdir -p "$CACHE/dl"
  local partial="$tarball.$$.partial"
  echo "Fetching Ghostty $GHOSTTY_TAG ($GHOSTTY_COMMIT)."
  curl --fail --silent --show-error --location \
    --output "$partial" \
    "https://codeload.github.com/ghostty-org/ghostty/tar.gz/$GHOSTTY_COMMIT"
  mv "$partial" "$tarball"
  FETCHED=1
}

# One hash over the extracted tree: every file's sha256 and every symlink's target, sorted. It
# does not depend on how the archive was compressed or ordered, so it holds if codeload
# regenerates the tarball bytes.
tree_hash() {
  (
    cd "$1"
    {
      find . -type f -exec shasum -a 256 {} +
      find . -type l -exec sh -c 'for link; do printf "link %s %s\n" "$link" "$(readlink "$link")"; done' sh {} +
    } | LC_ALL=C sort | shasum -a 256 | awk '{ print $1 }'
  )
}

# Source files that begin with .git are skipped, since Ghostty's build never reads them. The tree
# hash covers the tree without them.
extract_source() {
  mkdir -p "$1"
  tar -xzf "$CACHE/dl/$GHOSTTY_COMMIT.tar.gz" -C "$1" --strip-components=1 \
    --exclude='.gitmodules' --exclude='.gitattributes' --exclude='.gitignore' --exclude='.git'
}

verify_source() {
  local actual
  actual="$(tree_hash "$1")"
  if [ "$actual" != "${GHOSTTY_TREE_SHA256:-}" ]; then
    if [ "$FETCHED" = "1" ]; then
      rm -f "$CACHE/dl/$GHOSTTY_COMMIT.tar.gz"
    fi
    die "the Ghostty source for $GHOSTTY_COMMIT hashes to $actual, but ghostty.pin expects ${GHOSTTY_TREE_SHA256:-nothing}. The cached source is not what the pin names."
  fi
}

# Prints the tree hash for the pinned commit. Run it after bumping GHOSTTY_COMMIT, and record the
# result as GHOSTTY_TREE_SHA256 in ghostty.pin.
print_tree_hash() {
  fetch_source
  mkdir -p "$CACHE/tmp"
  WORK="$(mktemp -d "$CACHE/tmp/hash.XXXXXX")"
  extract_source "$WORK/src"
  tree_hash "$WORK/src"
}

build() {
  fetch_source

  mkdir -p "$CACHE/tmp" "$CACHE/zig-global" "$CACHE/artifacts"
  remove_stale_work
  WORK="$(mktemp -d "$CACHE/tmp/build.XXXXXX")"

  # The build runs without git, so Zig is given the version explicitly.
  extract_source "$WORK/src"
  verify_source "$WORK/src"

  local proxy_env=()
  if [ "$OFFLINE" = "1" ]; then
    # A dead proxy makes any attempt to fetch a package fail at once.
    proxy_env=(
      http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
      HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
    )
  fi

  echo "Building GhosttyKit for $KEY. This takes a few minutes."
  (
    cd "$WORK/src"
    env ${proxy_env[@]+"${proxy_env[@]}"} \
      ZIG_GLOBAL_CACHE_DIR="$CACHE/zig-global" \
      "$ZIG" build \
      --cache-dir "$WORK/zig-cache" \
      --prefix "$WORK/prefix" \
      -Doptimize=ReleaseFast \
      -Demit-xcframework=true \
      -Dxcframework-target=native \
      -Demit-macos-app=false \
      -Dversion-string="${GHOSTTY_TAG#v}"
  )

  local built="$WORK/src/macos/GhosttyKit.xcframework"
  [ -d "$built" ] || die "zig build did not produce GhosttyKit.xcframework."
  [ -d "$WORK/prefix/share/ghostty" ] || die "zig build did not install shell-integration resources."
  [ -d "$WORK/prefix/share/terminfo" ] || die "zig build did not install terminfo."

  mkdir -p "$WORK/out/share"
  mv "$built" "$WORK/out/GhosttyKit.xcframework"
  mv "$WORK/prefix/share/ghostty" "$WORK/out/share/ghostty"
  mv "$WORK/prefix/share/terminfo" "$WORK/out/share/terminfo"

  cat >"$WORK/out/manifest" <<EOF
GHOSTTY_TAG=$GHOSTTY_TAG
GHOSTTY_COMMIT=$GHOSTTY_COMMIT
ZIG_VERSION=$ZIG_VERSION
XCODE_VERSION=$XCODE_VERSION
XCODE_BUILD=$XCODE_BUILD
SDK_VERSION=$SDK_VERSION
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  # The rename is the commit point. A directory under a valid key is always complete.
  [ ! -e "$ARTIFACT" ] || die "$ARTIFACT appeared during the build. Run make build again."
  mv "$WORK/out" "$ARTIFACT"
}

main() {
  local mode="${1:-build}"
  read_pin
  read_toolchain
  check_toolchain
  compute_key

  case "$mode" in
  path)
    echo "$ARTIFACT"
    ;;
  tree-hash)
    trap cleanup EXIT
    print_tree_hash
    ;;
  verify)
    [ -d "$ARTIFACT" ] || die "GhosttyKit is not built. Run make build."
    check_manifest
    [ -e "$LINK_DIR/GhosttyKit.xcframework" ] || die "GhosttyKit.xcframework is not linked. Run make build."
    local target
    target="$(cd "$LINK_DIR/GhosttyKit.xcframework" && pwd -P)"
    [ "$target" = "$(cd "$ARTIFACT/GhosttyKit.xcframework" && pwd -P)" ] ||
      die "GhosttyKit.xcframework links a stale artifact. Run make build."
    ;;
  zig)
    # Only the path goes to stdout, so a caller can capture it.
    {
      acquire_lock
      ensure_zig
    } >&2
    echo "$ZIG"
    ;;
  build)
    if [ ! -d "$ARTIFACT" ]; then
      trap cleanup EXIT
      trap 'exit 130' INT TERM
      acquire_lock
      # Another process may have finished the same build while this one waited.
      if [ ! -d "$ARTIFACT" ]; then
        ensure_zig
        build
      fi
    fi
    check_manifest
    link_artifact
    echo "GhosttyKit ready: $KEY"
    ;;
  *)
    die "unknown mode: $mode"
    ;;
  esac
}

main "$@"
