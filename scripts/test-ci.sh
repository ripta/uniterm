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
  local tested="${8:-}"
  if CHANGES_RESULT="$changes" BUILD_REQUIRED="$required" TESTED="$tested" PACKAGE_RESULT="$package" \
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
expect_result "a tested tree passes with only the offline check" success true skipped skipped success 0 true
expect_result "a tested tree still needs the offline check" success true skipped skipped failure 1 true
expect_result "a tested tree with a skipped offline check fails" success true skipped skipped skipped 1 true
expect_result "a tested tree that ran the app job fails" success true skipped success success 1 true
expect_result "an untested tree needs every job" success true skipped skipped success 1 false
expect_result "a docs skip cannot carry a tested tree" success false skipped skipped skipped 1 true
expect_result "a malformed tested answer fails" success true skipped skipped success 1 maybe

# GitHub's API is the one outside input to the tested-tree check. The fake answers with JSON shaped
# like GitHub's and applies the script's own --jq filter with jq, so the filters are proved too.
fake_gh="$scratch/fake-gh"
cat >"$fake_gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api && "$3" == --jq ]] || exit 2
case "$2" in
  */commits/*/pulls) body="$FAKE_PULLS" ;;
  */git/commits/*) body="$FAKE_COMMIT" ;;
  */check-runs\?check_name=ci\&filter=latest) body="$FAKE_CHECKS" ;;
  *) exit 2 ;;
esac
[[ "$body" != fail ]] || exit 1
printf '%s' "$body" | jq -r "$4"
FAKE
chmod +x "$fake_gh"

# A PR branch off main, and GitHub's merge commit for it. The head holds main's previous commit,
# so the merge keeps the head's tree.
git -C "$repo" checkout --quiet --detach "$odd_doc"
printf 'PR\n' >"$repo/App/PR.swift"
pr_head="$(commit_fixture App/PR.swift)"
merged="$(git -C "$repo" commit-tree "$pr_head^{tree}" -p "$odd_doc" -p "$pr_head" -m Merge)"

# Main gains a change and reverts it while the PR is open. The merge's tree still equals the head's,
# but a PR run made between the two tested a merge that held the change.
git -C "$repo" checkout --quiet --detach "$odd_doc"
printf 'Gone\n' >"$repo/App/Gone.swift"
commit_fixture App/Gone.swift >/dev/null
git -C "$repo" rm --quiet App/Gone.swift
reverted="$(commit_fixture App/Gone.swift)"
remerged="$(git -C "$repo" commit-tree "$pr_head^{tree}" -p "$reverted" -p "$pr_head" -m Merge)"

merge_tree="$(git -C "$repo" rev-parse "$pr_head^{tree}")"
other_tree="$(git -C "$repo" rev-parse "$license^{tree}")"

pulls_json() {
  local merge_sha="$1" merged_at="${2:-2026-11-21T00:00:00Z}"
  printf '[{"number":82,"merged_at":"%s","merge_commit_sha":"%s","head":{"sha":"%s"}}]' \
    "$merged_at" "$merge_sha" "$pr_head"
}

checks_json() {
  local conclusions="$1" runs="" conclusion
  for conclusion in $conclusions; do
    runs+="${runs:+,}{\"name\":\"ci\",\"conclusion\":\"$conclusion\"}"
  done
  printf '{"total_count":%s,"check_runs":[%s]}' "$(wc -w <<<"$conclusions")" "$runs"
}

expect_tested() {
  local name="$1" event="$2" head="$3" pulls="$4" commit="$5" checks="$6" expected="$7" actual
  : >"$scratch/output"
  (
    cd "$repo"
    GITHUB_EVENT_NAME="$event" HEAD_SHA="$head" GITHUB_REPOSITORY=example/repo \
      CI_TESTED_TREE_GH="$fake_gh" FAKE_PULLS="$pulls" FAKE_COMMIT="$commit" FAKE_CHECKS="$checks" \
      GITHUB_OUTPUT="$scratch/output" bash "$root/scripts/ci-tested-tree.sh" >"$scratch/log" 2>&1
  )
  IFS= read -r actual <"$scratch/output"
  if [[ "$actual" != "tested=$expected" ]]; then
    echo "FAIL: $name: expected $expected, got $actual" >&2
    cat "$scratch/log" >&2
    exit 1
  fi
  echo "PASS: $name"
}

same_tree="{\"sha\":\"$pr_head\",\"tree\":{\"sha\":\"$merge_tree\"}}"
passed="$(checks_json success)"

expect_tested "a merge of a passing PR's exact tree is tested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" true
expect_tested "a PR head with another tree is untested" push "$merged" \
  "$(pulls_json "$merged")" "{\"tree\":{\"sha\":\"$other_tree\"}}" "$passed" false
expect_tested "a failed ci check is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json failure)" false
expect_tested "a ci check still running is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" '{"total_count":1,"check_runs":[{"name":"ci","conclusion":null}]}' false
expect_tested "no ci check is untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json "")" false
expect_tested "two ci checks are untested" push "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$(checks_json "success success")" false
expect_tested "an unmerged PR is untested" push "$merged" \
  "$(pulls_json "$merged" null | sed 's/"null"/null/')" "$same_tree" "$passed" false
expect_tested "a PR that only contains the commit is untested" push "$merged" \
  "$(pulls_json "$license")" "$same_tree" "$passed" false
expect_tested "two merged PRs naming the commit are untested" push "$merged" \
  "[$(pulls_json "$merged" | tr -d '[]'),$(pulls_json "$merged" | tr -d '[]')]" "$same_tree" "$passed" false
expect_tested "an unreadable PR list is untested" push "$merged" fail "$same_tree" "$passed" false
expect_tested "an unreadable PR head is untested" push "$merged" "$(pulls_json "$merged")" fail "$passed" false
expect_tested "an unreadable ci check is untested" push "$merged" "$(pulls_json "$merged")" "$same_tree" fail false
expect_tested "a PR event is never tested" pull_request "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a manual run is never tested" workflow_dispatch "$merged" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a malformed head is untested" push "not-a-sha" \
  "$(pulls_json "$merged")" "$same_tree" "$passed" false
expect_tested "a merge after main changed and changed back is untested" push "$remerged" \
  "$(pulls_json "$remerged")" "$same_tree" "$passed" false
expect_tested "a squash merge whose head is not in the clone is untested" push "$merged" \
  "$(pulls_json "$merged" | sed "s/$pr_head/2222222222222222222222222222222222222222/")" "$same_tree" "$passed" false
expect_tested "a head missing locally is untested" push aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$(pulls_json aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" "$same_tree" "$passed" false

# The offline job looks up main's Ghostty cache by the setup action's key. A key that drifted would
# miss on every tested push, and each one would rebuild Ghostty.
ghostty_keys() {
  grep -h -o 'key: ghostty-\${{ runner.arch }}-.*' "$@" | sort -u
}
setup_key="$(ghostty_keys "$root/.github/actions/macos-setup/action.yml")"
workflow_key="$(ghostty_keys "$root/.github/workflows/ci.yml")"
if [[ -z "$setup_key" || "$setup_key" != "$workflow_key" ]]; then
  echo "FAIL: the workflow's Ghostty cache key '$workflow_key' differs from the setup action's '$setup_key'" >&2
  exit 1
fi
echo "PASS: the offline job looks up the setup action's Ghostty cache key"

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

# A UI test build signs the helpers with Xcode's test exceptions, and a later plain build in the same
# folder keeps the app's copies of them. So the UI tests must never build where the helper sandbox
# probes and `make run` read the app.
derived_data_paths() {
  make -C "$root" -n "$1" | grep -o -- '-derivedDataPath [^ ]*' | sort -u
}

test_build_paths="$(derived_data_paths test-app)"
for target in build test-helper-sandbox; do
  if [[ -z "$test_build_paths" ]] || [[ "$(derived_data_paths "$target")" == "$test_build_paths" ]]; then
    echo "FAIL: make test-app builds into the same folder as make $target: $test_build_paths" >&2
    exit 1
  fi
done
echo "PASS: the UI tests build apart from the app the helper sandbox probes"

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
