#!/usr/bin/env bash
set -euo pipefail

# Lists UI test classes and their test counts from the built test bundle.
# Writes one line per class to stdout: "ClassName TestCount"
# Classes with zero tests are filtered out.
#
# Usage: list-ui-test-classes.sh <xcodebuild-args...>
#   The script builds xcodebuild arguments for test enumeration from the input.
#
# This script must run under the same screen lock as the UI test run.

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <xcodebuild-args...>" >&2
  exit 1
fi

# Create a temp directory for the JSON output.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

json_file="$scratch/enumeration.json"

# Run xcodebuild to enumerate tests, writing JSON to a file.
if ! "$@" test-without-building -enumerate-tests \
  -test-enumeration-style hierarchical \
  -test-enumeration-format json \
  -test-enumeration-output-path "$json_file" >/dev/null 2>&1; then
  echo "Error: xcodebuild test enumeration failed" >&2
  exit 1
fi

if [[ ! -f "$json_file" ]]; then
  echo "Error: enumeration JSON file not found: $json_file" >&2
  exit 1
fi

# Extract the UI test target's classes and their test counts.
# Filter out classes with 0 tests.
if ! jq -r '.values[0].children[] | select(.name == "uniterm UITests") | .children[] | "\(.name) \(.children | length)"' \
  "$json_file" 2>/dev/null | awk '$2 > 0'; then
  echo "Error: failed to parse enumeration JSON or no 'uniterm UITests' target found" >&2
  exit 1
fi

# Check that at least one class was output.
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  echo "Error: no classes with tests found" >&2
  exit 1
fi
