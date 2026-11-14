#!/usr/bin/env bash
#
# Runs a `swift test` command with a time limit on each test.
#
# Usage:
#   scripts/run-swift-tests.sh SECONDS command [argument ...]
#
# XCTest's standard output is block-buffered when it goes to a pipe, so a run that is cut short
# loses its last lines, and the log names the wrong test. NSUnbufferedIO makes it write each line
# as it goes.
#
# The script passes standard output through and notes which test is running. A test that runs past
# SECONDS is named, the process tree is printed, and each test process is sampled and then aborted.
# The command then fails with the abort's signal. A command that is still running after the abort
# is ended too, so a stuck run always ends in bounded time. Standard error is left alone.
#
# The limit should stay above the longest wait a failing test makes, so a failing test still
# reports its own assertion.

set -euo pipefail

usage() {
  echo "usage: $0 SECONDS command [argument ...]" >&2
  exit 64
}

[[ $# -ge 2 && "$1" =~ ^[1-9][0-9]*$ ]] || usage

limit="$1"
shift

# How often the watcher looks, and how long a command may outlive the abort.
poll="${RUN_SWIFT_TESTS_POLL:-5}"
grace="${RUN_SWIFT_TESTS_GRACE:-30}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/run-swift-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

state="$scratch/running"
pipe="$scratch/output"
mkfifo "$pipe"
: >"$state"

note() {
  echo "run-swift-tests: $*" >&2
}

descendants() {
  local child

  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

# Prints the stuck test's evidence, aborts each test process, and ends the command if the abort
# does not.
abort_run() {
  local name="$1" seconds="$2" pid found=0 waited=0

  note "$name has run for $seconds s, past the $limit s limit"
  ps -axo pid,ppid,pgid,stat,etime,command >&2 || true

  for pid in $(descendants "$runner"); do
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
      *xctest*)
        found=1
        note "sampling test process $pid"
        /usr/bin/sample "$pid" 3 >&2 2>&1 || true
        note "aborting test process $pid"
        kill -ABRT "$pid" 2>/dev/null || true
        ;;
    esac
  done

  [[ $found == 1 ]] || note "found no test process under $runner"

  while kill -0 "$runner" 2>/dev/null && ((waited < grace)); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$runner" 2>/dev/null; then
    note "the command outlived the abort by $grace s, so it is ended"
    kill -TERM "$runner" 2>/dev/null || true
    sleep 2
    kill -KILL "$runner" 2>/dev/null || true
  fi
}

watch_tests() {
  local started name now

  while sleep "$poll"; do
    read -r started name <"$state" || continue
    now="$(date +%s)"

    if ((now - started > limit)); then
      abort_run "$name" "$((now - started))"
      return
    fi
  done
}

# Each started test is written whole to a new file and moved into place, so the watcher never reads
# a line half written.
read_output() {
  local line name

  while IFS= read -r line; do
    printf '%s\n' "$line"

    case "$line" in
      "Test Case '"*"' started.")
        name="${line#"Test Case '"}"
        name="${name%"' started."}"
        printf '%s %s\n' "$(date +%s)" "$name" >"$state.next"
        mv "$state.next" "$state"
        ;;
      "Test Case '"*"' passed ("* | "Test Case '"*"' failed ("* | "Test Case '"*"' skipped ("*)
        : >"$state.next"
        mv "$state.next" "$state"
        ;;
    esac
  done <"$pipe"
}

read_output &
reader=$!

NSUnbufferedIO=YES "$@" >"$pipe" &
runner=$!

watch_tests &
watcher=$!

set +e
wait "$runner"
status=$?
set -e

kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true

# A process the command left behind can hold the output pipe open. The reader then never sees the
# pipe's end, so it gets a moment to drain and is then ended.
waited=0

while kill -0 "$reader" 2>/dev/null && ((waited < 10)); do
  sleep 1
  waited=$((waited + 1))
done

if kill -0 "$reader" 2>/dev/null; then
  note "a process the command left behind still holds its output, so the rest is dropped"
  kill "$reader" 2>/dev/null || true
fi

wait "$reader" 2>/dev/null || true

exit "$status"
