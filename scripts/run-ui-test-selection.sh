#!/usr/bin/env bash
set -euo pipefail

# Runs a UI test selection with xcodebuild and verifies the test count. Arguments: TEST_DERIVED_DATA
# UI_TESTS EXPECTED_TESTS UI_TEST_TARGET [xcodebuild_args...]. EXPECTED_TESTS may be empty.

test_derived_data="$1"
ui_tests="$2"
expected_tests="$3"
ui_test_target="$4"
shift 4

result_bundle="$test_derived_data/Logs/Test/$(date +%Y%m%d-%H%M%S)-$$.xcresult"

# Build the -only-testing arguments from UI_TESTS.
only_testing_args=()
for test in $ui_tests; do
  only_testing_args+=("-only-testing:$ui_test_target/$test")
done

scripts/run-ui-tests.sh "$@" -resultBundlePath "$result_bundle" "${only_testing_args[@]}" test

if [[ ! -d "$result_bundle" ]]; then
  echo "Error: result bundle not found: $result_bundle" >&2
  exit 1
fi

summary=$(xcrun xcresulttool get test-results summary --path "$result_bundle")
total_tests=$(echo "$summary" | jq '.totalTestCount')

if [[ "$total_tests" == "null" ]]; then
  echo "Error: failed to read test count from $result_bundle" >&2
  exit 1
fi

if [[ "$total_tests" -eq 0 ]]; then
  echo "Error: no tests ran. The selection '$ui_tests' matched nothing" >&2
  exit 1
fi

if [[ -n "$expected_tests" ]]; then
  if [[ "$total_tests" -ne "$expected_tests" ]]; then
    echo "Error: expected $expected_tests tests, but $total_tests ran" >&2
    exit 1
  fi
fi
