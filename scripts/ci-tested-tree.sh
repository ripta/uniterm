#!/usr/bin/env bash
set -euo pipefail

# A push to main whose tree is the exact tree a merged PR's head passed CI with needs no second
# package and app run. The PR run already built and tested those bytes. Main still runs the offline
# Ghostty check, since only main's runs save the Ghostty cache and the proof that PRs read.
#
# Any doubt builds. An unknown event, an unreadable answer from GitHub, no merged PR, more than one,
# a different tree, or a ci check that did not pass all leave tested=false.

tested=false
pr=""
event="${GITHUB_EVENT_NAME:-}"
head="${HEAD_SHA:-}"
repo="${GITHUB_REPOSITORY:-}"
gh="${CI_TESTED_TREE_GH:-gh}"

report() {
  echo "$1" >&2
}

find_tested_pr() {
  local heads head_tree pr_tree conclusions

  # The PR whose merge produced this commit. A rebase merge names its last commit, and a squash
  # merge names the squash commit, so this covers every merge method.
  if ! heads="$("$gh" api "repos/$repo/commits/$head/pulls" \
    --jq ".[] | select(.merged_at != null and .merge_commit_sha == \"$head\") | \"\(.number) \(.head.sha)\"")"; then
    report "Could not list the PRs that merged $head; running full CI."
    return 1
  fi

  if [[ -z "$heads" ]]; then
    report "No merged PR produced $head; running full CI."
    return 1
  fi

  if [[ "$heads" == *$'\n'* ]]; then
    report "More than one merged PR names $head; running full CI."
    return 1
  fi

  pr="${heads%% *}"
  local pr_head="${heads#* }"
  if ! [[ "$pr" =~ ^[0-9]+$ && "$pr_head" =~ ^[[:xdigit:]]{40}$ ]]; then
    report "GitHub's answer for $head was malformed; running full CI."
    return 1
  fi

  if ! head_tree="$(git rev-parse --verify --quiet "$head^{tree}")"; then
    report "Could not read the tree of $head; running full CI."
    return 1
  fi

  if ! pr_tree="$("$gh" api "repos/$repo/git/commits/$pr_head" --jq .tree.sha)"; then
    report "Could not read the tree of PR #$pr's head; running full CI."
    return 1
  fi

  if [[ "$pr_tree" != "$head_tree" ]]; then
    report "PR #$pr's head tree differs from $head, so this combination is untested; running full CI."
    return 1
  fi

  # filter=latest keeps only the newest ci check run, so a failure fixed by a rerun counts as passed.
  if ! conclusions="$("$gh" api "repos/$repo/commits/$pr_head/check-runs?check_name=ci&filter=latest" \
    --jq '.check_runs[].conclusion')"; then
    report "Could not read PR #$pr's ci check; running full CI."
    return 1
  fi

  if [[ "$conclusions" != success ]]; then
    report "PR #$pr's latest ci check reads '${conclusions//$'\n'/,}', not one success; running full CI."
    return 1
  fi

  return 0
}

if [[ "$event" == push && "$head" =~ ^[[:xdigit:]]{40}$ && "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
  if find_tested_pr; then
    tested=true
    report "PR #$pr passed ci on this exact tree; skipping the package and app jobs."
  fi
fi

echo "tested=$tested"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'tested=%s\n' "$tested" >>"$GITHUB_OUTPUT"
fi
