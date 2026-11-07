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
  local name="$1" changes="$2" required="$3" build="$4" expected="$5" actual
  if CHANGES_RESULT="$changes" BUILD_REQUIRED="$required" BUILD_RESULT="$build" \
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

expect_result "intentional docs skip passes" success false skipped 0
expect_result "successful full build passes" success true success 0
expect_result "detector failure fails" failure false skipped 1
expect_result "build failure fails" success true failure 1
expect_result "cancelled build fails" success true cancelled 1
expect_result "unexpected skipped build fails" success true skipped 1
expect_result "missing decision fails" success "" skipped 1
expect_result "malformed decision fails" success maybe skipped 1
expect_result "unexpected work on docs path fails" success false failure 1
