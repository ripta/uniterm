#!/usr/bin/env bash
#
# Collects the testmanagerd and UI test runner log from a failed UI test run.
# Usage: collect-ui-test-log.sh <start_time_seconds> <output_path>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <start_time_seconds> <output_path>" >&2
  exit 1
fi

start_time="$1"
output_path="$2"

echo "Collecting testmanagerd log from the run..."

# Predicate: every testmanagerd line, plus the runner's own test-mark, issue-mark, and frontmost
# lines. The subsystem match is enough without matching the bundle path, since the subsystem is
# unique to this runner.
predicate="process == 'testmanagerd' OR subsystem == 'dev.uniterm.uitests'"

# Decide whether to compress the output.
if [[ "$output_path" == *.gz ]]; then
  compress=true
  temp_log="$(mktemp "${TMPDIR:-/tmp}/uniterm-kept-log.XXXXXX")"
else
  compress=false
  temp_log="$output_path"
fi

# Run log show from the start time. The --info flag includes the default level.
if log show --style compact --info --start "$(date -r "$start_time" '+%Y-%m-%d %H:%M:%S')" \
    --predicate "$predicate" >"$temp_log" 2>&1; then

  # Check if the log has any event lines. An empty log says so.
  if grep -q 'testmanagerd' "$temp_log"; then
    if [[ "$compress" == true ]]; then
      gzip -c "$temp_log" >"$output_path"
      rm -f "$temp_log"
    fi
    echo "Kept log written to: $output_path"
  else
    echo "No testmanagerd lines found in the log window" | tee "$temp_log"
    if [[ "$compress" == true ]]; then
      gzip -c "$temp_log" >"$output_path"
      rm -f "$temp_log"
    fi
    echo "Kept log written to: $output_path"
  fi
else
  echo "error: log show failed. The kept log may be incomplete." >&2
  echo "log show failed" >"$temp_log"
  if [[ "$compress" == true ]]; then
    gzip -c "$temp_log" >"$output_path"
    rm -f "$temp_log"
  fi
  echo "Kept log written to: $output_path"
fi
