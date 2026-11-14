#!/usr/bin/env bash
set -euo pipefail

# Real Git history exercises classification and the final status gate, not GitHub's scheduler.
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init --quiet "$repo"
git -C "$repo" config user.name "CI fixture"
git -C "$repo" config user.email "ci-fixture@example.invalid"
git -C "$repo" config commit.gpgsign false
mkdir -p "$repo/spec/proposals" "$repo/App" "$repo/Licenses"

commit_fixture() {
  local path
  for path in "$@"; do
    if [[ -e "$repo/$path" ]]; then
      git -C "$repo" add -- "$path" || return
    fi
  done
  git -C "$repo" -c core.hooksPath=/dev/null commit --quiet -m "Fixture" -- "$@" || return
  git -C "$repo" rev-parse HEAD
}

expect_changes() {
  local name="$1" event="$2" base="$3" head="$4" expected="$5" actual
  : >"$scratch/output"
  (
    cd "$repo"
    GITHUB_EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head" \
      GITHUB_OUTPUT="$scratch/output" bash "$root/scripts/ci-changes.sh" >"$scratch/log" 2>&1
  )
  IFS= read -r actual <"$scratch/output"
  if [[ "$actual" != "build_required=$expected" ]]; then
    echo "FAIL: $name: expected $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_result() {
  local name="$1" changes="$2" required="$3" package="$4" app="$5" ghostty="$6" expected="$7" actual
  if CHANGES_RESULT="$changes" BUILD_REQUIRED="$required" PACKAGE_RESULT="$package" \
    APP_RESULT="$app" GHOSTTY_OFFLINE_RESULT="$ghostty" \
    bash "$root/scripts/ci-result.sh" >"$scratch/log" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name: expected exit $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

printf 'Initial\n' >"$repo/README.md"
printf 'Initial\n' >"$repo/spec/proposals/plan.md"
printf 'Initial\n' >"$repo/App/Main.swift"
printf 'Initial\n' >"$repo/Licenses/LICENSE.md"
initial="$(commit_fixture README.md spec/proposals/plan.md App/Main.swift Licenses/LICENSE.md)"

printf 'Root docs\n' >>"$repo/README.md"
root_docs="$(commit_fixture README.md)"
expect_changes "root Markdown skips on push" push "$initial" "$root_docs" false
expect_changes "root Markdown skips on PR" pull_request "$initial" "$root_docs" false

printf 'Proposal\n' >>"$repo/spec/proposals/plan.md"
spec_docs="$(commit_fixture spec/proposals/plan.md)"
expect_changes "nested spec Markdown skips" pull_request "$root_docs" "$spec_docs" false

printf 'Code\n' >>"$repo/App/Main.swift"
code="$(commit_fixture App/Main.swift)"
expect_changes "code builds" push "$spec_docs" "$code" true

printf 'Later docs\n' >>"$repo/README.md"
later_docs="$(commit_fixture README.md)"
expect_changes "PR includes earlier code commits" pull_request "$initial" "$later_docs" true
expect_changes "push uses before rather than PR history" push "$code" "$later_docs" false

printf 'Mixed\n' >>"$repo/README.md"
printf 'Mixed\n' >>"$repo/App/Main.swift"
mixed="$(commit_fixture README.md App/Main.swift)"
expect_changes "mixed changes build" push "$later_docs" "$mixed" true

printf 'License\n' >>"$repo/Licenses/LICENSE.md"
license="$(commit_fixture Licenses/LICENSE.md)"
expect_changes "bundled Markdown builds" push "$mixed" "$license" true

git -C "$repo" mv App/Main.swift Notes.md
renamed="$(commit_fixture App/Main.swift Notes.md)"
expect_changes "code renamed to Markdown builds" push "$license" "$renamed" true

git -C "$repo" rm --quiet README.md
deleted_docs="$(commit_fixture README.md)"
expect_changes "deleted documentation skips" push "$renamed" "$deleted_docs" false

git -C "$repo" mv Notes.md App/New.swift
renamed_back="$(commit_fixture Notes.md App/New.swift)"
expect_changes "Markdown renamed to code builds" push "$deleted_docs" "$renamed_back" true

printf 'Workflow\n' >"$repo/spec/workflow.yml"
non_markdown="$(commit_fixture spec/workflow.yml)"
expect_changes "non-Markdown spec files build" push "$renamed_back" "$non_markdown" true

odd_path=$'spec/proposals/line\nbreak.md'
printf 'Odd name\n' >"$repo/$odd_path"
odd_doc="$(commit_fixture "$odd_path")"
expect_changes "newline in documentation path is safe" push "$non_markdown" "$odd_doc" false

# A PR compares against the merge base, not changes made only on its base branch.
git -C "$repo" checkout --quiet --detach "$non_markdown"
printf 'Base-only code\n' >>"$repo/App/New.swift"
advanced_base="$(commit_fixture App/New.swift)"
expect_changes "PR uses merge-base comparison" pull_request "$advanced_base" "$odd_doc" false

expect_changes "manual dispatch always builds" workflow_dispatch "$initial" "$root_docs" true
expect_changes "unknown events build" schedule "$initial" "$root_docs" true
expect_changes "initial push builds" push 0000000000000000000000000000000000000000 "$root_docs" true
expect_changes "missing revisions build" push "" "$root_docs" true
expect_changes "unavailable history builds" push aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$root_docs" true
expect_changes "empty diff builds conservatively" push "$root_docs" "$root_docs" true

expect_result "intentional docs skip passes" success false skipped skipped skipped 0
expect_result "successful full build passes" success true success success success 0
expect_result "detector failure fails" failure false skipped skipped skipped 1
expect_result "package failure fails" success true failure success success 1
expect_result "app failure fails" success true success failure success 1
expect_result "Ghostty offline failure fails" success true success success failure 1
expect_result "cancelled job fails" success true success cancelled success 1
expect_result "unexpected skipped job fails" success true success success skipped 1
expect_result "missing job result fails" success true success "" success 1
expect_result "missing decision fails" success "" skipped skipped skipped 1
expect_result "malformed decision fails" success maybe skipped skipped skipped 1
expect_result "unexpected work on docs path fails" success false skipped failure skipped 1
expect_result "unexpected success on docs path fails" success false success skipped skipped 1

# The proven key must change with every input of the offline rebuild, and must never repeat on a
# runner that reports no image version.
proof="$scratch/proof"
proof_inputs=(ghostty.pin scripts/build-ghostty.sh scripts/ghostty-offline-check.sh
  scripts/ghostty-proof-key.sh .github/workflows/ci.yml .github/actions/macos-setup/action.yml)
for path in "${proof_inputs[@]}"; do
  mkdir -p "$proof/$(dirname "$path")"
  cp "$root/$path" "$proof/$path"
done

proof_key() {
  env -u GITHUB_OUTPUT GHOSTTY_PROOF_ROOT="$proof" RUNNER_ARCH=ARM64 "$@" \
    bash "$root/scripts/ghostty-proof-key.sh" | sed -n 's/^key=//p'
}

expect_keys() {
  local name="$1" relation="$2" first="$3" second="$4"
  if [[ -z "$first" || -z "$second" ]]; then
    echo "FAIL: $name: a key was empty" >&2
    exit 1
  fi
  if [[ "$relation" == same && "$first" != "$second" ]] ||
    [[ "$relation" == different && "$first" == "$second" ]]; then
    echo "FAIL: $name: expected $relation keys, got $first and $second" >&2
    exit 1
  fi
  echo "PASS: $name"
}

image=(ImageOS=macos26 ImageVersion=20261101.1)
baseline="$(proof_key "${image[@]}")"

expect_keys "same inputs and image give the same key" same "$baseline" "$(proof_key "${image[@]}")"
expect_keys "a new runner image changes the key" different "$baseline" \
  "$(proof_key ImageOS=macos26 ImageVersion=20261108.1)"

for path in "${proof_inputs[@]}"; do
  cp "$proof/$path" "$scratch/saved"
  printf '\n# changed\n' >>"$proof/$path"
  expect_keys "a change to $path changes the key" different "$baseline" "$(proof_key "${image[@]}")"
  cp "$scratch/saved" "$proof/$path"
done

expect_keys "restored inputs give the first key again" same "$baseline" "$(proof_key "${image[@]}")"

unknown_first="$(proof_key ImageOS= ImageVersion= GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1)"
unknown_second="$(proof_key ImageOS= ImageVersion= GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1)"
expect_keys "no image version never repeats a key" different "$unknown_first" "$unknown_second"

rm "$proof/ghostty.pin"
if proof_key "${image[@]}" >/dev/null 2>&1 && [[ -n "$(proof_key "${image[@]}" 2>/dev/null)" ]]; then
  echo "FAIL: a missing input still produced a key" >&2
  exit 1
fi
echo "PASS: a missing input produces no key"

# The swift test watchdog samples with macOS's `sample`, so it is proved only on macOS. The changes
# job runs these checks on Linux, and the package job runs them again on macOS.
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: the package test time limit runs only on macOS"
  exit 0
fi

# The watchdog runs fake test commands. A copy of `sleep` named xctest stands in for the test
# process, so the abort path runs against a real child without building any tests. macOS kills a
# copied system binary at launch, so the copy is signed again, ad hoc.
watch_dir="$scratch/watch"
mkdir -p "$watch_dir"
cp /bin/sleep "$watch_dir/xctest"
codesign --force --sign - "$watch_dir/xctest" 2>/dev/null

cat >"$watch_dir/passing" <<'FAKE'
#!/usr/bin/env bash
echo "Test Case '-[Suite testOne]' started."
echo "Test Case '-[Suite testOne]' passed (0.001 seconds)."
echo "after the tests"
FAKE

cat >"$watch_dir/failing" <<'FAKE'
#!/usr/bin/env bash
echo "Test Case '-[Suite testOne]' started."
echo "Test Case '-[Suite testOne]' failed (0.001 seconds)."
exit 3
FAKE

cat >"$watch_dir/stuck" <<FAKE
#!/usr/bin/env bash
echo "Test Case '-[Suite testStuck]' started."
"$watch_dir/xctest" 60
FAKE

cat >"$watch_dir/slow-run" <<'FAKE'
#!/usr/bin/env bash
for name in testFirst testSecond testThird; do
  echo "Test Case '-[Suite $name]' started."
  sleep 1.5
  echo "Test Case '-[Suite $name]' passed (1.500 seconds)."
done
FAKE

chmod +x "$watch_dir/passing" "$watch_dir/failing" "$watch_dir/stuck" "$watch_dir/slow-run"

run_watch() {
  local limit="$1" command="$2"
  RUN_SWIFT_TESTS_POLL=1 RUN_SWIFT_TESTS_GRACE=5 \
    bash "$root/scripts/run-swift-tests.sh" "$limit" "$watch_dir/$command" \
    >"$scratch/watch-out" 2>"$scratch/watch-err"
}

expect_watch_status() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name: expected exit $expected, got $actual" >&2
    cat "$scratch/watch-out" "$scratch/watch-err" >&2
    exit 1
  fi
}

expect_watch_text() {
  local name="$1" file="$2" text="$3"
  if ! grep -qF -- "$text" "$scratch/$file"; then
    echo "FAIL: $name: $file lacks: $text" >&2
    cat "$scratch/watch-out" "$scratch/watch-err" >&2
    exit 1
  fi
}

status=0
run_watch 30 passing || status=$?
expect_watch_status "a passing run passes its status through" 0 "$status"
expect_watch_text "a passing run passes its output through" watch-out "after the tests"
if [[ -s "$scratch/watch-err" ]]; then
  echo "FAIL: a passing run wrote to standard error" >&2
  cat "$scratch/watch-err" >&2
  exit 1
fi
echo "PASS: a passing run is passed through untouched"

status=0
run_watch 30 failing || status=$?
expect_watch_status "a failing run passes its status through" 3 "$status"
echo "PASS: a failing run keeps its status"

status=0
started_at="$(date +%s)"
run_watch 2 stuck || status=$?
elapsed=$(($(date +%s) - started_at))
if [[ "$status" == 0 ]]; then
  echo "FAIL: a stuck test passed" >&2
  exit 1
fi
expect_watch_text "a stuck test is named" watch-err "-[Suite testStuck] has run for"
expect_watch_text "a stuck test process is sampled" watch-err "sampling test process"
expect_watch_text "a stuck test process is aborted" watch-err "aborting test process"
if ((elapsed > 40)); then
  echo "FAIL: a stuck test took $elapsed s to end" >&2
  exit 1
fi
echo "PASS: a stuck test is named, sampled, and aborted"

status=0
run_watch 2 slow-run || status=$?
expect_watch_status "a run longer than the limit, of short tests, passes" 0 "$status"
expect_watch_text "a run longer than the limit keeps every test" watch-out "-[Suite testThird]' passed"
echo "PASS: the limit applies to each test, not to the run"
