#!/usr/bin/env bash
# Ends xctest processes that outlived the `swift test` that started them.
#
# SwiftPM runs xctest in a process group of its own, so a signal to the `swift test` or make group
# never reaches it. A healthy orphan dies on its next write to the closed pipe. A hung test writes
# nothing, so it stays until someone ends it. The package's test bundle links a guard that exits
# when its runner does, so this is the backstop for a bundle built without it.
#
# Only processes whose parent is launchd qualify, and only those running a bundle under the given
# build directories. A live test run in this checkout or any other is never touched.
#
# Usage: clean-test-processes.sh [--dry-run] <build directory>...
set -euo pipefail

# How long a process gets to act on SIGTERM before SIGKILL.
readonly grace_seconds=5

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--dry-run] <build directory>..." >&2
  exit 2
fi

orphans() {
  local line command directory

  # pgrep exits 1 when nothing matches, which is the ordinary case.
  #
  # The directories are compared as literal strings, since a path is not a safe regular expression
  # and a pattern that went wrong would reach other checkouts' processes.
  while read -r line; do
    command="${line#* }"

    for directory in "$@"; do
      if [[ "$command" == *" $directory/"*"PackageTests.xctest" ]]; then
        echo "${line%% *}"
        break
      fi
    done
  done < <(pgrep -P 1 -fl '/xctest ' || true)
}

pids="$(orphans "$@")"

if [[ -z "$pids" ]]; then
  echo "no orphaned test processes"
  exit 0
fi

for pid in $pids; do
  echo "orphaned xctest: $pid"
done

if [[ "$dry_run" -eq 1 ]]; then
  exit 0
fi

# shellcheck disable=SC2086
kill -TERM $pids 2>/dev/null || true

for _ in $(seq "$grace_seconds"); do
  sleep 1

  [[ -z "$(orphans "$@")" ]] && {
    echo "ended"
    exit 0
  }
done

remaining="$(orphans "$@")"

if [[ -n "$remaining" ]]; then
  echo "still running after ${grace_seconds}s, sending SIGKILL: $(echo "$remaining" | tr '\n' ' ')"

  # shellcheck disable=SC2086
  kill -KILL $remaining 2>/dev/null || true
fi

echo "ended"
