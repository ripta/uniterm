#!/usr/bin/env bash
#
# Fails when any code outside the terminal surface module can reach GhosttyKit.
#
# libghostty is reached only through the terminal surface protocol. So only the TerminalSurface
# target may depend on GhosttyKit, and only its own sources and tests may import it. Inside that
# module, the import must be `internal import`, so no libghostty type leaks through public API.
#
# Usage: scripts/check-ghosttykit-imports.sh [root]
# The optional root lets a test point the check at a scratch copy of the tree.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
status=0

fail() {
  echo "error: $*" >&2
  status=1
}

# An import is any line that starts with optional modifiers, `import`, and a GhosttyKit module path.
# `@_exported` and `public` re-export the module, so they get their own message.
import_pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*(public[[:space:]]+|package[[:space:]]+|internal[[:space:]]+|fileprivate[[:space:]]+|private[[:space:]]+)?(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(struct[[:space:]]+|class[[:space:]]+|enum[[:space:]]+|func[[:space:]]+|var[[:space:]]+|let[[:space:]]+|typealias[[:space:]]+|protocol[[:space:]]+)?GhosttyKit([[:space:].]|$)'

allowed_dirs=(
  "Packages/UnitermKit/Sources/TerminalSurface"
  "Packages/UnitermKit/Tests/TerminalSurfaceTests"
)

while IFS= read -r file; do
  relative="${file#"$ROOT"/}"

  allowed=0
  for dir in "${allowed_dirs[@]}"; do
    case "$relative" in
    "$dir"/*) allowed=1 ;;
    esac
  done

  if [ "$allowed" = "0" ]; then
    fail "$relative imports GhosttyKit. Only the TerminalSurface module may."
    continue
  fi

  case "$relative" in
  Packages/UnitermKit/Sources/TerminalSurface/*)
    if grep -Eq '^[[:space:]]*(@_exported[[:space:]]+|public[[:space:]]+|package[[:space:]]+)+import[[:space:]]+GhosttyKit' "$file"; then
      fail "$relative re-exports GhosttyKit. Use \`internal import GhosttyKit\`."
    elif grep -E "$import_pattern" "$file" | grep -vEq '^[[:space:]]*internal[[:space:]]+import[[:space:]]+GhosttyKit'; then
      fail "$relative must use \`internal import GhosttyKit\`."
    fi
    ;;
  esac
done < <(grep -rlE "$import_pattern" "$ROOT/App" "$ROOT/Helpers" "$ROOT/UITests" "$ROOT/Packages/UnitermKit/Sources" "$ROOT/Packages/UnitermKit/Tests" --include='*.swift' 2>/dev/null || true)

# Only TerminalSurface may list GhosttyKit as a dependency in the package manifest.
manifest="$ROOT/Packages/UnitermKit/Package.swift"
if [ -f "$manifest" ]; then
  while IFS= read -r line; do
    fail "Package.swift names GhosttyKit outside the TerminalSurface target: $line"
  done < <(
    python3 -I - "$manifest" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
for match in re.finditer(r"\.(target|testTarget|executableTarget)\(\s*name:\s*\"([A-Za-z0-9_]+)\"", text):
    start = match.start()
    depth = 0
    end = start
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                end = index
                break
    body = text[start:end]
    if "GhosttyKit" in body and match.group(2) != "TerminalSurface":
        print(" ".join(body.split()))
PY
  )
fi

# The Xcode project must not link GhosttyKit into the app directly.
project="$ROOT/uniterm.xcodeproj/project.pbxproj"
if [ -f "$project" ] && grep -q 'GhosttyKit' "$project"; then
  if grep -E 'GhosttyKit' "$project" | grep -vEq 'Verify GhosttyKit|GhosttyKit\.xcframework/Info\.plist|build-ghostty|ghostty-verified'; then
    fail "uniterm.xcodeproj references GhosttyKit outside the build verification step."
  fi
fi

if [ "$status" = "0" ]; then
  echo "GhosttyKit is imported only by the TerminalSurface module."
fi

exit "$status"
