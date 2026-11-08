#!/usr/bin/env bash
set -euo pipefail

if [[ "${CHANGES_RESULT:-}" != success ]]; then
  echo "Change detection did not succeed." >&2
  exit 1
fi

# Each macOS job, with its result. A job is skipped only when the whole build is, so every job
# must match the build decision. A job that ends early inside its own steps still succeeds.
jobs=(
  "package=${PACKAGE_RESULT:-}"
  "app=${APP_RESULT:-}"
  "ghostty-offline=${GHOSTTY_OFFLINE_RESULT:-}"
)

case "${BUILD_REQUIRED:-}" in
  false)
    expected=skipped
    ;;
  true)
    expected=success
    ;;
  *)
    echo "Change detection produced no valid build decision." >&2
    exit 1
    ;;
esac

failed=false
for job in "${jobs[@]}"; do
  name="${job%%=*}"
  result="${job#*=}"
  if [[ "$result" != "$expected" ]]; then
    echo "The $name job's result is '${result:-missing}', and this change needs '$expected'." >&2
    failed=true
  fi
done

if [[ "$failed" == true ]]; then
  exit 1
fi

if [[ "$expected" == skipped ]]; then
  echo "Documentation-only changes; macOS builds and tests skipped."
else
  echo "Full CI passed."
fi
