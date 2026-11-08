#!/usr/bin/env bash
#
# Prints the cache key that records a passing offline Ghostty rebuild. CI saves an entry under this
# key after the rebuild passes, and skips the rebuild when the entry already exists.
#
# The key names everything the rebuild depends on: the repo files that drive it, the runner's
# architecture, and the runner image, which carries Xcode and the SDK. The workflow and its setup
# action are among the files, since the action selects the Xcode and the workflow runs the check.
#
# A runner that reports no image version gets a key no saved entry can match, so the rebuild runs.
# A key that matches too rarely costs one rebuild. A key that matches too often would skip a check.

set -euo pipefail

ROOT="${GHOSTTY_PROOF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

inputs=(
  ghostty.pin
  scripts/build-ghostty.sh
  scripts/ghostty-offline-check.sh
  scripts/ghostty-proof-key.sh
  .github/workflows/ci.yml
  .github/actions/macos-setup/action.yml
)

if command -v sha256sum >/dev/null; then
  digest=(sha256sum)
else
  digest=(shasum -a 256)
fi

# A missing input fails the digest, and set -e stops the script before it prints a key.
listing="$(cd "$ROOT" && "${digest[@]}" -- "${inputs[@]}")"
files="$(printf '%s\n' "$listing" | "${digest[@]}" | cut -c1-16)"

arch="${RUNNER_ARCH:-$(uname -m)}"

if [[ -n "${ImageVersion:-}" ]]; then
  image="${ImageOS:-unknown}-$ImageVersion"
else
  image="unknown-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$RANDOM$RANDOM"
fi

key="ghostty-offline-proven-$arch-$image-$files"

echo "key=$key"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'key=%s\n' "$key" >>"$GITHUB_OUTPUT"
fi
