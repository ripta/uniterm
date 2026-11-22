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

# A tree that a merged PR already passed skips only the package and app jobs. The offline Ghostty
# check still runs, so it must still succeed. Only a build decision can carry a tested tree.
case "${TESTED:-false}" in
  false)
    tested=false
    ;;
  true)
    if [[ "$expected" != success ]]; then
      echo "A documentation-only change cannot also carry a tested tree." >&2
      exit 1
    fi
    tested=true
    ;;
  *)
    echo "The tested-tree check produced no valid answer." >&2
    exit 1
    ;;
esac

failed=false
for job in "${jobs[@]}"; do
  name="${job%%=*}"
  result="${job#*=}"
  want="$expected"
  if [[ "$tested" == true && ("$name" == package || "$name" == app) ]]; then
    want=skipped
  fi

  if [[ "$result" != "$want" ]]; then
    echo "The $name job's result is '${result:-missing}', and this change needs '$want'." >&2
    failed=true
  fi
done

if [[ "$failed" == true ]]; then
  exit 1
fi

if [[ "$expected" == skipped ]]; then
  echo "Documentation-only changes; macOS builds and tests skipped."
elif [[ "$tested" == true ]]; then
  echo "A merged PR already passed this tree; the offline Ghostty check passed."
else
  echo "Full CI passed."
fi
