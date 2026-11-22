# UTERM-044: Shard CI's UI Tests Across macOS Runners

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-22

## Impacts

- UTERM-045: "How the tests are divided" sets where the launcher test runs. Under today's counts the second shard
  starts with `LaunchServicesOpenUITests` and then `LauncherUITests`, so the launcher test runs third after a cold
  start, where in one `app` job it ran mid-suite. 045's test-level clean run names no job or shard, so its count reads
  the same either way.

## Summary

CI's `app` job runs every UI test on one macOS runner. This proposal splits the UI tests into shards that run side by
side on separate runners. A full run gets shorter, and so does the rerun after a flaky failure, since only the failed
shard reruns.

## Motivation

The `app` job sets the length of every CI run. In the first `app` run of #90, the job started at 04:39:46 and ended at
05:15:29. About 5 minutes went to the builds and the helper sandbox checks before the first UI test. Then 176 UI tests
ran for 1831 seconds, about 30.5 minutes, one at a time. The UI tests cannot run in parallel on one runner: they share
its one screen, and `scripts/run-ui-tests.sh` holds a lock on it. The suite has since grown on the development branch to
204 tests in 33 classes.

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
a way to skip them by accident. "How CI selects a shard, and how a shard runs locally" below gives the shard target.

### One required check

Decision: the `ci` job stays the only required check. It passes only when every shard matches the build decision, as it
requires of the three macOS jobs today.

Rationale: branch protection names `ci`. Keeping one aggregate check means a new shard count never touches the
repository's settings.

### Every skip covers every shard

Decision: a documentation-only change skips every shard, as it skips the `app` job today. A tree that a merged PR
already passed skips every shard too. The commits "Skip main's package and app jobs when a merged PR passed the same
tree" and "Skip main's jobs only when the PR head held main's previous commit" add that skip for the `package` and `app`
jobs, and both are on `main`.

### The helper sandbox checks run once

Decision: `make test-helper-sandbox` runs in exactly one CI job per run, never split and never repeated. It runs against
the plain build, as `make ci-app` does today.

Rationale: ADR-10 makes the helper sandbox checks the proof that each helper is sandboxed and the app is not. The test
build in `DerivedData-test` signs the helpers with Xcode's test exceptions, so it cannot serve that proof.

### How the tests are divided

- **Fixed class lists.** Each shard names its classes. Easy to read. Shards drift out of balance as classes grow.
- **Xcode test plans.** One plan per shard. The scheme has no test plan today, and adding plans changes what `make
  test-app` runs, so the default plan must stay the whole suite.
- **By measured duration.** A script assigns classes from recorded durations. Balanced, but it needs a place to keep
  the durations, and a fallback when one is missing.
- **At run time, by count.** Each shard lists the test classes the build holds and takes its share, balanced by test
  count. No list to keep and no drift. Adds a split script. The largest class, `QuestionsUITests`, holds 24 of 203
  tests, so no class alone unbalances a 2- or 3-way split.

Decision: at run time, by test count, in contiguous ranges of the name order. Each shard lists the UI test classes in
the test build it just made and sorts them by name under `LC_ALL=C`. The sorted list is cut into as many runs as there
are shards. Each class goes to the shard whose range holds the midpoint of its tests in the running count, so each cut
falls at the class boundary nearest an equal share. The shard count and each shard's index come from one matrix
definition in the workflow, so every shard computes the same partition. A whole class stays in one shard.

Rationale: membership follows the build, so a new class runs in some shard with no list to keep and nothing to drift.
Each shard is a slice of the whole-suite order, so every class but a shard's first keeps the predecessor it has in `make
test-app`, which is what the flaky-test log investigates by. One changed test count moves at most one class at each cut.
On today's 204 tests in 33 classes, three shards get 69, 66, and 69 tests. A largest-first greedy split would get an
exact 68 each, but one added test would move 18 to 26 of the 33 classes between shards. A class's neighbors in CI would
then change with unrelated PRs and match no local run. Fixed class lists and test plans leave a new class needing an
entry, and test plans also change what `make test-app` runs. A split by measured duration needs a committed durations
file, and no CI path can refresh it: the workflow holds `contents: read`, a fork's PR cannot write, and results upload
only on failure. Durations fetched at run time would let a rerun compute a different partition from the first attempt
and skip a class. A split by test method gains little balance over a class split, and it breaks rerunning a class in its
original order.

Leaves undone: balance rests on test count as a proxy for time, and no per-class durations exist to confirm it. The
cuts fall at class boundaries, so a shard can run up to about half the largest class over an equal share, about 12 tests
or 2 minutes. M1
records each shard's test time, so an imbalance shows. A split weighted by committed durations is the upgrade path, and
only the weight input would change.

### Build once or build per shard

- **Build per shard.** Each shard builds the app, about 5 minutes. The shards build in parallel, so a full run loses
  nothing. Each shard stands alone.
- **Build once.** One job runs `build-for-testing` and uploads the products. Each shard downloads them and runs
  `test-without-building`. A full run gets slightly longer: the build, then a second runner's setup and download, then
  the tests. A rerun saves about 5 minutes. Uploads may drop executable bits and symlinks unless the products are
  archived first, and a rerun needs the artifact still retained.

Decision: build per shard. Each shard job makes its own test build and runs its share.

Rationale: a full run is shortest, since the shards build in parallel and nothing waits on a build job. Each shard runs
the same build-then-test path as a local run, with no artifact, archive, retention, or cross-runner image to go wrong.
Build once saves about 5 minutes per one-shard rerun. It costs a runner start, a checkout, and a download on every full
run, and it needs the products archived so bundle symlinks and signatures survive. Caching products by tree would press
on the repository's cache quota, which main's Ghostty cache depends on.

Leaves undone: each one-shard rerun repeats the roughly 5-minute test build. UTERM-045 and UTERM-046 shrink how often a
rerun happens.

### Where the helper sandbox checks run

The checks need their own plain Xcode build and a SwiftPM build. Whichever job runs them becomes longer.

- **In one shard.** That shard takes fewer test classes to balance its extra build. No new job.
- **In the `package` job.** It reuses that job's SwiftPM build, and adds a plain app build to `package`, which already
  sets the 15-minute floor.
- **In their own job.** Every shard is alike. Costs one more macOS slot per run while it runs.

Decision: in the `package` job. `ci-package` runs `test-helper-sandbox` after `test-package`, so the helper run reuses
the package test build in `.build/swiftpm`. The job gains only the plain Xcode app build.

Rationale: it is the one host that reuses a build it already has. It adds no job, no macOS slot, no result case, and no
special case in the split. Both skips already cover `package`. At two shards it would add no wall time, since `package`
grows to about 17 minutes against shards of about 21 to 23. At three shards it costs about 2 minutes per full run, and
both other placements cost more there. In one shard, the run grows by the whole helper overhead, about 2
to 3 minutes, and that shard's UI reruns repeat it. A weight for that shard in the split would be a special case that
drifts. Its own job pays a fresh SwiftPM build and a slot, and at three shards a run would start 6 macOS jobs against a
cap of 5. Every shard running the checks would reverse "The helper sandbox checks run once".

Leaves undone: a rerun of `package` after a package-test flake repeats the plain build, about 2 minutes. At three shards,
`package` is the longest job by a minute or two.

### How CI selects a shard, and how a shard runs locally

Every flag a UI run needs lives in the Makefile's `test-app` recipe: the time allowances, `-test-timeouts-enabled`, and
`-collect-test-diagnostics never`. The Makefile also says each CI job's target lets a failed job be rerun locally.

- **A shard target.** `make test-app-shard SHARD=n` runs one shard with the same flags. `make test-app` stays whole. A
  failed shard reruns locally in its original order.
- **Selection in the workflow.** The workflow calls `xcodebuild` with its own copy of the flags, and a `make test-ci`
  check fails when the copies differ. Reproducing a shard locally means copying its selection by hand.

- **The workflow computes the split.** A script picks the classes and passes them to `make test-app-select
  UI_TESTS='...'`. The run flags stay in one place, but the build and the class listing still need the Makefile's paths
  or a new target. Reproducing a shard means pasting a logged list.

Decision: a shard target. `make test-app-shard SHARD=i SHARDS=n` makes the test build, lists the classes, runs the
split, logs the selection, and runs that share through `test-app-select`'s selection path with the same flags. The
workflow calls it from a matrix job. On the tree CI built, it reruns a failed shard's share with the same command. A
pull request's run builds the merge of the PR into `main`, so on the PR's head alone the share can differ by a boundary
class. The logged `make test-app-select` line is the exact reproduction on any tree.

Rationale: the flags, the build, the listing, the split, and the run stay in one place. It keeps the Makefile's promise
that each CI job's target reruns that job locally, on the tree CI built. Selection in the workflow copies the flags and
then polices the copy. A workflow script feeding `test-app-select` still leaks the build and listing paths into the
workflow.

A matrix job reports one aggregate result to `ci`: failure when any shard fails. So `ci`'s needs and its result check
keep their `app` entry, and the shards need no entries of their own.

### How a new test class finds a shard

A class that no shard runs would silently stop running in CI.

- **A check.** `make test-ci` fails when a UI test class is in no shard, or in two. It runs on Linux in the `changes`
  job, so it parses Swift source, and its correctness rests on the parser.
- **A catch-all shard.** The last shard runs every class the others do not name, with its skip list derived from theirs.
  Correct by construction. The last shard grows out of balance over time.
- **Both.** The catch-all keeps every class running, and a check flags the imbalance.
- **Not needed.** The run-time split above leaves no list for a class to be missing from.

Decision: not needed beyond the split. A new `UITests/*.swift` file joins the UI test target through the project's
synchronized folder, with no project edit. Every shard builds the same commit, lists the same classes, and runs the
same split, so a new class lands in exactly one shard.

Rationale: the run-time split leaves no list for a class to be missing from. A check that parses Swift on Linux
duplicates what the built bundle gives, and a parser that disagrees with the compiler fails both ways. A catch-all shard
guards only against a listing that drops a class in every shard alike. With Xcode pinned and Xcode's own listing, no
such path is known. It would earn its place only if the listing came from another source.

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

- **Four.** A run starts 6 macOS jobs against the cap of 5, so a lone run queues one of its own jobs. A shard job takes
  about 12 to 13 minutes, but `package` still sets the run's length, so a full run is no shorter than with three. A
  one-shard rerun is about 3 minutes shorter than with three.

Decision: three shards, as one matrix value. The figures in the options above predate the move of the helper checks into
`package`, which puts `package` at about 17 minutes.

Rationale: a lone run ends when `package` does, about 17 minutes, against about 22 with two shards. A one-shard rerun
takes about 15 to 16 minutes, about 6 minutes shorter than with two. That rerun gain is arithmetic on the test time,
whatever the shard overhead turns out to be. Each run uses about the same slot-minutes at every count, so under the cap
the count decides latency, not throughput. Two runs that start together end at about 17 and 31 to 34 minutes with three
shards, against 22 and 34 to 39 with two, so the extra queueing does not make the second run slower. Four shards let a
lone run queue against itself, and a full run is no shorter.

Leaves undone: `package` becomes the critical path, so the helper checks there cost about 2 minutes per full run. Near
234 tests, or sooner if a shard's overhead is 5 minutes rather than 3 to 4, a shard passes `package` and the count
needs revisiting. A lone run takes all 5 macOS slots at start, so any other macOS workload in the organization queues
this one. Each shard adds a first test, and the Risks section suspects first tests of cold-launch flakes. A later count
change edits `ci.yml`, which is an input to the offline Ghostty proof key, so that run's `ghostty-offline` rebuilds
once. M1's own change to `ci.yml` does the same once.

## Design Decisions (Open)

None.

## Risks

- **A test class runs in no shard** — likelihood: low, impact: high.
  Mitigation: each shard takes its classes from its own build and runs the same split, so a new class lands in exactly
  one shard. Each shard also checks that the split of its own listing puts every class in exactly one shard, and a
  `make test-ci` case proves the split on fixtures. Neither check can see two shards' listings disagree. That needs two
  builds of one commit with one pinned Xcode to list different classes, and `UITests/` has no conditional compilation.
- **Runs queue behind the concurrency cap** — likelihood: medium, impact: medium.
  Mitigation: the shard count is chosen against the cap. At three shards a lone run takes all 5 macOS slots at start,
  and two runs that start together end at about 17 and 31 to 34 minutes, no later than with two shards. A queued run is
  slower, not wrong. Another repository in the organization that runs macOS jobs would queue this one further. The
  count is one matrix value, so it changes in one line when that happens.
- **More shards mean more cold first launches** — likelihood: medium, impact: low.
  Mitigation: two logged flakes hit the first test of a run, suspected but not confirmed to be cold launches. Each shard
  has a first test. Each CI entry in the flaky-test log records whether the test ran first in its shard job, with the
  shard's logged selection, so a first-test pattern shows.
- **The class listing does not work on the CI runner** — likelihood: low, impact: medium.
  Mitigation: the split reads its classes from the built test bundle, through `xcodebuild -enumerate-tests` or an
  equivalent listing. It is not yet proved on a CI runner. The runner has a GUI session, since today's `app` job passes
  `run-ui-tests.sh`'s session check. The unknown is whether listing launches the UI test runner, and so can meet the
  same cold-launch failures before any test runs. M1 proves it first. If no listing from the build works there, the
  division decision reopens before the split is built, since a fallback that parses Swift source is a different design.
- **A Ghostty pin change rebuilds Ghostty in every build job** — likelihood: low, impact: low.
  Accepted: on a pin or patch change the setup action misses its exact cache key, so `package` and each of the three
  shards rebuild Ghostty from the fallback cache, 4 rebuilds where today there are 2. Each shard's job grows by that
  build, on those runs only.
- **Sharding changes the context of a flake under recount** — likelihood: medium, impact: low.
  Mitigation: UTERM-045's launcher recount counts clean runs of a test that, after sharding, runs third in the second
  shard, right after a cold start. One cut shift can make `LauncherUITests` that shard's first class. Its predecessor,
  `LaunchServicesOpenUITests`, stays the same as in a full run. A recount that spans the landing of this proposal
  notes the landing in the launcher entry, so a change in rate can be read against it.
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
- The shards run as one matrix job, and `ci` keeps one `app` entry in its needs and in its result check
- A failing shard leaves the other shards running to completion, and rerunning failed jobs reruns only the failed shard
- Each failing shard uploads its results under its own name
- A documentation-only change skips every shard, and so does an already-tested tree
- Every shard lists the classes in the same order, a `make test-ci` case proves the split covers every class exactly
  once for each shard count in use, and each shard logs its selection so a local rerun can copy it
- The shard count and every shard's index come from one matrix definition, passed as `strategy.job-index` and
  `strategy.job-total`, so no shard can split by a different count
- `make test-app-shard` fails when `SHARD` or `SHARDS` is empty, not a number, or out of range
- The class sort is pinned to `LC_ALL=C`, so a runner's or a laptop's locale cannot move a class between shards
- Each shard computes the whole partition from its own listing and fails unless every class lands in exactly one shard
  and the listing holds at least one test
- A shard fails when it ran fewer tests than its selection named, so a selected name that matches nothing cannot pass
- A local `make test-app-select` line that names a class the local tree lacks fails loudly and never passes on zero
  tests
- A class whose test midpoint lands exactly on a cut has one defined owner, and the `make test-ci` split fixture pins it
- Each shard logs a `make test-app-select UI_TESTS='...'` line that reruns its share locally
- `ci-package` runs `test-helper-sandbox` after `test-package`, never two `swift test` runs at once on one scratch path,
  and `make ci` runs the helper sandbox checks exactly once
- The comment above `ci` and the README name each CI job's local target, and `ci-app` says what it runs now that no job
  runs it
- Each shard's class list comes from the built test bundle, and a selected class not in the bundle fails CI
- The first shard job proves on a real CI runner that the class listing works there, before the split depends on it
- Listing the classes runs under the same screen lock as the UI run
- The split script runs on the Linux `changes` runner, where its `make test-ci` fixture case runs
- CI passes `SHARD` in the same base, 0 or 1, that `make test-app-shard` documents and validates, and the logged command
  and the job's name use it
- `test-app-shard` builds into the UI test build folder, and the `make test-ci` folder check covers it beside `test-app`
- Each failing shard's results artifact is named by its shard and its run attempt, so a failed rerun does not lose them
- `spec/flaky-tests.md`'s Rule asks each CI entry to record whether the test ran first in its shard job, and the
  shard's logged selection
- The measured length of a full CI run, of a one-shard rerun, of `package`, and of each shard's setup, build, and test
  time are recorded in the As built block, with the suite size at which a shard's job would pass `package`

## Decision Log

- 2026-11-21: Filed after a landing run that lost several hours to UI flake reruns. The user chose to pursue sharding,
  and asked whether the Free plan allows it. The repository is public, so macOS minutes are free, and the cap of 5
  concurrent macOS jobs is the constraint.
- 2026-11-21: A design review added the open questions on where the helper sandbox checks run and how a shard is
  selected and reproduced locally, and corrected the build-once option's benefit.
- 2026-11-22: Review start: 1 milestone, 4 settled decisions, 5 risks, 0 `**Live after:**` lines or row gates; no
  out-of-scope section, and "Local runs keep the whole suite" bounds the scope; reviewed as of the commit "Schedule
  UTERM-018, 040, 039, 033, 048, and 049 at the end of the queue"; an autonomous review of the 6 open questions.
- 2026-11-22: Divide the UI tests at run time by test count, from the classes in the built test bundle, with the shard
  count and index from one matrix definition. Converged in 1 pass. (autonomous)
- 2026-11-22: Build the UI tests in each shard rather than once for all shards. Converged in 1 pass. (autonomous)
- 2026-11-22: Run the helper sandbox checks in the `package` job, after the package tests, reusing their SwiftPM
  build. Converged in 2 passes. (autonomous)
- 2026-11-22: Select a shard through a `make test-app-shard SHARD=i SHARDS=n` target that a matrix job calls.
  Converged in 1 pass. (autonomous)
- 2026-11-22: A new UI test class needs no check or catch-all, since the run-time split takes classes from the build.
  Converged in 1 pass. (autonomous)
- 2026-11-22: Run three UI test shards, as one matrix value. Converged in 2 passes, after the first pass showed the
  extra queueing at three does not make a second concurrent run slower. (autonomous)
- 2026-11-22: The whole-proposal review reopened the division mechanism. Cut the name-sorted classes into contiguous
  ranges by test count, in place of a largest-first greedy split, so one changed test moves at most a boundary class
  and each class keeps its whole-suite predecessor. (autonomous)
- 2026-11-22: The shard target reproduces a share only on the tree CI built, since a PR run builds the merge with
  `main`. The logged `make test-app-select` line is the exact reproduction. (autonomous)
- 2026-11-22: Recorded the Ghostty rebuild cost of a pin change across the build jobs as an accepted low risk, reframed
  the class-listing risk, and narrowed the no-shard risk's mitigation to what each shard can see. (autonomous)
- 2026-11-22: The cold-launch risk's mitigation adds two fields to every CI entry in `spec/flaky-tests.md`'s Rule:
  whether the test ran first in its shard job, and the shard's logged selection. M1 makes the Rule change.
  (autonomous, addition)
- 2026-11-22: Coherence and risk review converged in 2 passes: one full pass and one re-check. Added the risk that
  sharding moves the launcher test next to a cold start during UTERM-045's recount. (autonomous)
- 2026-11-22: Review gate: kept all. The split by contiguous ranges of sorted class names, the matrix job, the helper
  sandbox checks in `package`, three shards, and the flaky-log fields for first-in-shard and selection all stand. No
  decision gets an ADR. Status set to accepted.
- 2026-11-22: Scheduled as UTERM-044 M1 in queue.md.

## References

- ADR-10: App unsandboxed, helpers sandboxed
- `spec/flaky-tests.md`
- [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)
