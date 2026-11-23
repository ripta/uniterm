#!/usr/bin/env bash
#
# Fails when a test opens a named defaults domain without the TestDefaults helper.
#
# A named domain leaves a plist in ~/Library/Preferences. Emptying it with removePersistentDomain
# does not delete the file, and cfprefsd rewrites an emptied file about 20 seconds later. Only
# TestDefaults.discard() deletes it for good. So only DefaultsTestSupport may open a suite or
# write a persistent domain by name.
#
# Usage: scripts/check-test-defaults.sh [root]
# The optional root lets a test point the check at a scratch copy of the tree.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HELPER_DIR="Packages/UnitermKit/Tests/DefaultsTestSupport"
status=0

fail() {
  echo "error: $*" >&2
  status=1
}

pattern='UserDefaults[[:space:]]*\([[:space:]]*suiteName:|setPersistentDomain[[:space:]]*\('

while IFS= read -r match; do
  relative="${match#"$ROOT"/}"
  file="${relative%%:*}"
  rest="${relative#*:}"
  line="${rest%%:*}"

  case "$file" in
  "$HELPER_DIR"/*) continue ;;
  esac

  fail "$file:$line opens a named defaults domain. Use TestDefaults from DefaultsTestSupport."
done < <(grep -rnE "$pattern" "$ROOT/Packages/UnitermKit/Tests" "$ROOT/UITests" --include='*.swift' 2>/dev/null || true)

if [ "$status" = "0" ]; then
  echo "Tests open named defaults domains only through TestDefaults."
fi

exit "$status"
