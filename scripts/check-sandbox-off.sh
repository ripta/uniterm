#!/usr/bin/env bash
#
# Fails when the app could run inside the App Sandbox. A sandboxed app cannot give the shell its
# user's home folder, so the terminal would break.
#
# The check reads the Xcode project and any entitlements file. A built app can be checked as well:
#   scripts/check-sandbox-off.sh path/to/uniterm.app
#
# The image decoder helper is the one executable that must be sandboxed. Its entitlements file lives
# outside App/, so the check on the app stays as strict as before. The check also asserts that the
# helper holds the sandbox and no file or network entitlement, in the source file and in the copy
# inside a built app.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/uniterm.xcodeproj/project.pbxproj"
status=0

fail() {
  echo "error: $*" >&2
  status=1
}

settings="$(grep -E 'ENABLE_APP_SANDBOX' "$PROJECT" || true)"
[ -n "$settings" ] || fail "$PROJECT does not set ENABLE_APP_SANDBOX."
if printf '%s\n' "$settings" | grep -vq 'ENABLE_APP_SANDBOX = NO;'; then
  fail "ENABLE_APP_SANDBOX is not NO everywhere in $PROJECT."
fi

if grep -rq 'com.apple.security.app-sandbox' "$ROOT/App" 2>/dev/null; then
  fail "an entitlements file under App/ turns the App Sandbox on."
fi

# Only the image decoder's build configurations may name an entitlements file, and none may name a
# file that turns the App Sandbox on unless it belongs to the decoder.
while IFS= read -r problem; do
  fail "$problem"
done < <(
  python3 -I - "$PROJECT" <<'PY'
import re
import sys

project = sys.argv[1]
text = open(project).read()
blocks = re.split(r"(?=\n\t\t[0-9A-F]{24} /\* [A-Za-z]+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;)", text)

for block in blocks:
    if "isa = XCBuildConfiguration;" not in block:
        continue
    helper = "PRODUCT_NAME = ImageDecoder;" in block
    for value in re.findall(r"CODE_SIGN_ENTITLEMENTS = ([^;]+);", block):
        value = value.strip().strip('"')
        if not helper:
            print(f"a build configuration outside the image decoder names {value} as its entitlements.")
        elif value != "Helpers/ImageDecoder/ImageDecoder.entitlements":
            print(f"the image decoder names {value} as its entitlements.")
PY
)

HELPER_ENTITLEMENTS="$ROOT/Helpers/ImageDecoder/ImageDecoder.entitlements"
# Entitlements that would give the helper a way to read files or reach the network.
helper_forbidden='com\.apple\.security\.(files|network|temporary-exception|inherit|device|personal-information|assets|print|automation|cs\.)'

if [ ! -f "$HELPER_ENTITLEMENTS" ]; then
  fail "$HELPER_ENTITLEMENTS is missing."
else
  grep -A1 'com.apple.security.app-sandbox' "$HELPER_ENTITLEMENTS" | grep -q '<true/>' ||
    fail "the image decoder's entitlements do not set the App Sandbox to true."
  if grep -Eq "$helper_forbidden" "$HELPER_ENTITLEMENTS"; then
    fail "the image decoder's entitlements grant file or network access."
  fi
fi

if [ "$#" -ge 1 ]; then
  if codesign -d --entitlements - "$1" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
    fail "$1 carries the App Sandbox entitlement."
  fi

  helper="$1/Contents/Helpers/ImageDecoder"
  if [ ! -x "$helper" ]; then
    fail "$helper is missing from the built app."
  else
    signed="$(codesign -d --entitlements - "$helper" 2>/dev/null || true)"
    printf '%s\n' "$signed" | grep -A2 'com.apple.security.app-sandbox' | grep -q 'Bool\] true' ||
      fail "the built image decoder does not carry the App Sandbox entitlement set to true."
    if printf '%s\n' "$signed" | grep -Eq "$helper_forbidden"; then
      fail "the built image decoder carries a file or network entitlement."
    fi
  fi
fi

if [ "$status" = "0" ]; then
  echo "The App Sandbox is off."
fi

exit "$status"
