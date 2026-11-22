# UTERM-044: Shard CI's UI Tests Across macOS Runners

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Summary

CI's `app` job runs every UI test on one macOS runner. This proposal splits the UI tests into shards that run side by
side on separate runners. A full run gets shorter, and so does the rerun after a flaky failure, since only the failed
shard reruns.

## Motivation

The `app` job sets the length of every CI run. In the first `app` run of #90, the job started at 04:39:46 and ended at
05:15:29. About 5 minutes went to the builds and the helper sandbox checks before the first UI test. Then 176 UI tests
ran for 1831 seconds, about 30.5 minutes, one at a time. The UI tests cannot run in parallel on one runner: they share
its one screen, and `scripts/run-ui-tests.sh` holds a lock on it. The suite has since grown on the development branch to
203 tests in 33 classes.

A flaky UI test costs a full `app` run again. `gh run rerun --failed` reruns the whole job. On 2026-11-21 the launcher
scroll flake alone cost #83, #87, and #90 one or two extra 35-minute runs each. A landing run lands its batches one
after another, so each extra run delays every batch behind it.

The other jobs set a floor. #91's `package` job ran from 05:40:31 to 05:55:50, about 15 minutes. No shard count makes a
run shorter than its longest job.

The repository is public, and the space-armada organization is on GitHub's Free plan. Standard GitHub-hosted runners,
macOS included, are free and unlimited for public repositories. The constraint is concurrency: the Free plan runs at most
5 macOS jobs at once across the organization, out of 20 jobs in total. A CI run starts 3 macOS jobs: `package`, `app`,
and `ghostty-offline`. On a pull request, `ghostty-offline` usually finds main's proof in the cache and ends within
minutes, so a run holds 2 macOS slots for most of its length.

## Design Decisions (Settled)

### Local runs keep the whole suite

Decision: `make test-app` and `make ci-app` keep running every UI test. Sharding is a property of the CI workflow.

Rationale: a local run is how a developer proves a change before pushing. A plain local run that skipped tests would be
a way to skip them by accident. How CI selects a shard, and how a shard is reproduced locally, is an open question
below.

### One required check

Decision: the `ci` job stays the only required check. It passes only when every shard matches the build decision, as it
requires of the three macOS jobs today.

Rationale: branch protection names `ci`. Keeping one aggregate check means a new shard count never touches the
repository's settings.

### Every skip covers every shard

Decision: a documentation-only change skips every shard, as it skips the `app` job today. A tree that a merged PR
already passed skips every shard too, once that skip is on `main`. The commits "Skip main's package and app jobs when a
merged PR passed the same tree" and "Skip main's jobs only when the PR head held main's previous commit" add it for the
`package` and `app` jobs, and have not landed yet.

### The helper sandbox checks run once

Decision: `make test-helper-sandbox` runs in exactly one CI job per run, never split and never repeated. It runs against
the plain build, as `make ci-app` does today.

Rationale: ADR-10 makes the helper sandbox checks the proof that each helper is sandboxed and the app is not. The test
build in `DerivedData-test` signs the helpers with Xcode's test exceptions, so it cannot serve that proof.

## Design Decisions (Open)

### Where the helper sandbox checks run

The checks need their own plain Xcode build and a SwiftPM build. Whichever job runs them becomes longer.

- **In one shard.** That shard takes fewer test classes to balance its extra build. No new job.
- **In the `package` job.** It reuses that job's SwiftPM build, and adds a plain app build to `package`, which already
  sets the 15-minute floor.
- **In their own job.** Every shard is alike. Costs one more macOS slot per run while it runs.

### How many shards

The counts below assume the helper checks ride in an existing job. Their own job adds one slot.

At #90's rate of about 10.4 s per test, the 203-test suite takes about 35 minutes on one runner. Each shard also pays its
runner setup and its own test build, a few minutes.

- **Two.** A run starts 4 macOS jobs and holds 3 once `ghostty-offline` ends. A shard runs about 17.6 minutes of tests,
  so its job takes about 21 to 23 minutes. A one-shard rerun takes the same.
- **Three.** A run starts 5 macOS jobs and holds 4 once `ghostty-offline` ends, so a second run at the same time often
  queues. A shard runs about 11.7 minutes of tests, so its job takes about 15 to 17 minutes, at or just above the
  15-minute `package` floor. That is about 6 minutes shorter than two shards, for a full run and for a rerun. The full-run
  gain assumes `package` keeps its 15-minute floor. With the helper checks moved into `package`, it is closer to 4.

A fix PR next to a batch PR, as on 2026-11-21, is the common case for two runs at once. A push to `main` adds a third,
unless the tested-tree skip applies to it, which it does only when the merged PR's head held `main`'s previous commit.

### How CI selects a shard, and how a shard runs locally

Every flag a UI run needs lives in the Makefile's `test-app` recipe: the time allowances, `-test-timeouts-enabled`, and
`-collect-test-diagnostics never`. The Makefile also says each CI job's target lets a failed job be rerun locally.

- **A shard target.** `make test-app-shard SHARD=n` runs one shard with the same flags. `make test-app` stays whole. A
  failed shard reruns locally in its original order.
- **Selection in the workflow.** The workflow calls `xcodebuild` with its own copy of the flags, and a `make test-ci`
  check fails when the copies differ. Reproducing a shard locally means copying its selection by hand.

### How the tests are divided

- **Fixed class lists.** Each shard names its classes. Easy to read. Shards drift out of balance as classes grow.
- **Xcode test plans.** One plan per shard. The scheme has no test plan today, and adding plans changes what `make
  test-app` runs, so the default plan must stay the whole suite.
- **By measured duration.** A script assigns classes from recorded durations. Balanced, but it needs a place to keep
  the durations, and a fallback when one is missing.
- **At run time, by count.** Each shard lists the test classes the build holds and takes its share, balanced by test
  count. No list to keep and no drift. Adds a split script. The largest class, `QuestionsUITests`, holds 24 of 203
  tests, so no class alone unbalances a 2- or 3-way split.

### Build once or build per shard

- **Build per shard.** Each shard builds the app, about 5 minutes. The shards build in parallel, so a full run loses
  nothing. Each shard stands alone.
- **Build once.** One job runs `build-for-testing` and uploads the products. Each shard downloads them and runs
  `test-without-building`. A full run gets slightly longer: the build, then a second runner's setup and download, then
  the tests. A rerun saves about 5 minutes. Uploads may drop executable bits and symlinks unless the products are
  archived first, and a rerun needs the artifact still retained.

### How a new test class finds a shard

A class that no shard runs would silently stop running in CI.

- **A check.** `make test-ci` fails when a UI test class is in no shard, or in two. It runs on Linux in the `changes`
  job, so it parses Swift source, and its correctness rests on the parser.
- **A catch-all shard.** The last shard runs every class the others do not name, with its skip list derived from theirs.
  Correct by construction. The last shard grows out of balance over time.
- **Both.** The catch-all keeps every class running, and a check flags the imbalance.
- **Not needed.** The run-time split above leaves no list for a class to be missing from.

## Risks

- **A test class runs in no shard** — likelihood: medium, impact: high.
  Mitigation: whichever answer the open question above picks, every UI test class runs in exactly one shard, and CI
  fails when it does not.
- **Runs queue behind the concurrency cap** — likelihood: medium, impact: medium.
  Mitigation: the shard count is chosen against the cap. A queued run is slower, not wrong.
- **More shards mean more cold first launches** — likelihood: medium, impact: low.
  Mitigation: two logged flakes hit the first test of a run, suspected but not confirmed to be cold launches. Each shard
  has a first test. The flaky-test log records which shard a failure ran in, so a first-test pattern shows.
- **The Free plan's limits change** — likelihood: low, impact: medium.
  Mitigation: shards are a workflow setting. Reverting the workflow returns to one `app` job.
- **Splitting moves a flake rather than fixing it** — likelihood: high, impact: low.
  Accepted: a shorter rerun is the goal. Fixing flakes is UTERM-045 and UTERM-046.

## Milestones

### M1: Shard the app job

**Status:** NOT STARTED

- Every UI test class runs in exactly one shard, and CI fails when one does not
- A shard that runs no tests, or a selection that names a class that does not exist, fails CI
- The helper sandbox checks run once per CI run, against the plain build
- `ci` fails when any shard fails, and passes only when every shard matches the build decision
- A `make test-ci` check fails when a shard job is missing from `ci`'s needs or from its result check
- A failing shard leaves the other shards running to completion, and rerunning failed jobs reruns only the failed shard
- Each failing shard uploads its results under its own name
- A documentation-only change skips every shard, and so does an already-tested tree once that skip is on `main`
- When the helper sandbox checks run in their own job, both skips cover that job, and `ci` requires its result
- Under a run-time split, every shard lists the classes in the same order, a `make test-ci` case proves the split
  covers every class once, and each shard logs its selection so a local rerun can copy it
- Under a run-time split, each shard's class list comes from the built test bundle, and a class missing from it fails CI
- The measured length of a full CI run, and of a one-shard rerun, are recorded in the As built block

## Decision Log

- 2026-11-21: Filed after a landing run that lost several hours to UI flake reruns. The user chose to pursue sharding,
  and asked whether the Free plan allows it. The repository is public, so macOS minutes are free, and the cap of 5
  concurrent macOS jobs is the constraint.
- 2026-11-21: A design review added the open questions on where the helper sandbox checks run and how a shard is
  selected and reproduced locally, and corrected the build-once option's benefit.

## References

- ADR-10: App unsandboxed, helpers sandboxed
- `spec/flaky-tests.md`
- [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)
