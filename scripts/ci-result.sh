#!/usr/bin/env bash
set -euo pipefail

if [[ "${CHANGES_RESULT:-}" != success ]]; then
  echo "Change detection did not succeed." >&2
  exit 1
fi

case "${BUILD_REQUIRED:-}" in
  false)
    if [[ "${BUILD_RESULT:-}" != skipped ]]; then
      echo "Documentation-only CI has unexpected build results." >&2
      exit 1
    fi
    echo "Documentation-only changes; macOS build and tests skipped."
    ;;
  true)
    if [[ "${BUILD_RESULT:-}" != success ]]; then
      echo "The required macOS build job did not succeed." >&2
      exit 1
    fi
    echo "Full CI passed."
    ;;
  *)
    echo "Change detection produced no valid build decision." >&2
    exit 1
    ;;
esac
