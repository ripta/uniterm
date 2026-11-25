# UTERM-044 M1: shard the app job

Started 2026-11-25, as the second row of a `/work-queue` run of `next 7`. The run's state is in
[the UTERM-045 M1 report](20261124-uterm-045-m1-launcher-change-holds-in-ci.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Move UTERM-045 M1's finished row to history". The row has no dependency and no `Live after` line.

## UTERM-044 M1

### Plan

- A split script, written in bash and awk, cuts the name-sorted UI test classes into contiguous ranges by test count.
- `make test-app-shard SHARD=i SHARDS=n` builds, lists the classes from the built bundle under the screen lock, logs
  the selection, and runs that share.
- CI's `app` job becomes a three-shard matrix. The helper sandbox checks move into `ci-package`.

### Best guesses from the plan

- The CI-only checks split into a new UTERM-044 M2 by amendment, since the run never pushes. M2 takes the first shard
  job's proof that the listing works on a real runner, the measured run lengths, and the proof that a rerun reruns
  only the failed shard. If this is wrong, M1 stays `IN PROGRESS` until a pushed run.
- The split is built before CI proves the class listing. The Risks section orders those the other way. A local listing
  proof stands in. M2 reopens the division decision if the runner's listing fails.
- The split script is bash and awk, to match `scripts/` and run on the Linux `changes` runner.

### What was built

- `scripts/list-ui-test-classes.sh` lists the classes and their test counts from the built bundle. It uses
  `xcodebuild -enumerate-tests` with JSON written to a file. The Makefile runs it under `scripts/run-ui-tests.sh`, so
  it holds the screen lock. The pinned Xcode is 26.6, build 17F113.
- `scripts/shard-ui-tests.sh` sorts under `LC_ALL=C` and assigns each class with integer arithmetic. The rule is
  ceil(twice the midpoint times SHARDS over twice the total), so an exact cut goes to the lower shard. It writes the
  shard's test count to a file argument.
- `make test-app-shard SHARD=i SHARDS=n` takes a 0-based SHARD. CI passes `strategy.job-index` and
  `strategy.job-total`. It logs a `make test-app-select UI_TESTS='...' EXPECTED_TESTS=n` line.
- `make test-app-select` writes an explicit result bundle and reads `totalTestCount` with `xcresulttool`. It fails on
  zero tests, and on fewer than `EXPECTED_TESTS`.
- `ci-package` runs `test-helper-sandbox` after `test-package`. `ci-app` is now only the local full UI run.
- M1 is `DONE`. The new M2, "The shards run on CI", takes the CI-only checks. The queue gains a `UTERM-044 M2` row
  after `UTERM-044 M1`.

### Checks

- `make fmt-check`, `make lint`, `make check`: pass.
- `make test-ci`: pass, 83 checks. These include every shard of each split fixture, a 33-class fixture, and the
  folder check for `test-app-shard`.
- The listing on the real build gave 33 classes and 206 tests.
- `make test-app-select UI_TESTS='BrowserRemoteUITests'` passed with `EXPECTED_TESTS=1`. With `EXPECTED_TESTS=2` it
  failed with "expected 2 tests, but 1 ran". A made-up class failed with "no tests ran".
- The coordinator ran all three shards through `make test-app-shard SHARDS=3` under `caffeinate -dimsu`:

| Shard | Classes | Tests | Test time | Whole run |
|---|---|---|---|---|
| 0 | 10 | 69 | 354 s | 364 s |
| 1 | 10 | 67 | 295 s | 307 s |
| 2 | 13 | 70 | 302 s | 315 s |

  All passed, so the three shards together cover the 206 tests once. No new crash report appeared during the runs.
  The `xctest` SIGABRT reports from 02:32 to 03:02 match each `make test-ci` run. Their stack is a bare `nanosleep`,
  which fits the watchdog fixture that `test-ci` aborts on purpose.
- Test cost: the three shards' test phases sum to about 16 minutes. Earlier full `make test-app` runs under
  `caffeinate` averaged about 26 minutes, by `cg stats`. This run did not measure why the two differ.

### Review

The reviewer and the coordinator found these. All were fixed in four rounds with the same implementer:

- The ran-test count grepped `TestSummaries.plist`, which current bundles lack. So every selection failed. Found by
  the reviewer.
- The midpoint arithmetic misplaced classes when a share was not a whole number. For example, A 3, B 1, C 6 over three
  shards gave B to shard 0 and C to shard 1. Found by a coordinator probe. The reviewer had called the arithmetic
  correct.
- The selected-test count matched the whole space-separated class list as one pattern, so it was always empty. Found by
  the coordinator.
- The workflow hardcoded the shard list and count, not `strategy.job-index` and `strategy.job-total`. Found by the
  reviewer.
- The "fewer tests ran than selected" check was missing after the first fix. The split's errors went into its count
  file. A missing field read as 0. Bundle names could collide. Found by the coordinator.
- The started count left out skipped tests, and `UITests/UnitermUITestCase.swift:165` throws `XCTSkip`. Found by the
  coordinator.
- The listing step failed end to end. jq got non-JSON stdout, and nested quoting mangled awk. The implementer's proofs
  had run each piece by hand. Found by the coordinator's first shard run.
- The `test-app-shard` folder check printed PASS unconditionally. The split fixtures checked only shard 0. Two fixture
  comments were wrong. The As built block was one unwrapped paragraph. The Decision Log entry did not quote the changed
  text. Found by the coordinator.

`adr-impact` found the diff consistent with ADR-10. The helper sandbox checks still run once, against the plain build.
It found no uncovered decision. `proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin `other`.

### Row review

A fresh reviewer read the milestone commit. It found every M1 bullet met. It traced the failed-shard upload, the
optional `EXPECTED_TESTS`, the count file, and the shard index base, and found them consistent. One finding was
CONFIRMED:

- `test-app-shard` called `$(MAKE) test-app-select` on its last recipe line. Make runs such a line even under
  `make -n`. So the folder check's `make -n test-app-shard` read shard files a fresh checkout lacks, and exited 2. The
  check passed only because it ignored make's exit status.

A fresh implementer fixed it in "Run a UI test selection without recursive make". The selection run moved into
`scripts/run-ui-test-selection.sh`, which takes values only. `test-app-select` and `test-app-shard` both call it.
`test-app-shard` reads its shard files in a plain recipe line, which `make -n` only prints. The folder check now fails
when `make -n` fails. The coordinator sent back one round: the first version read its arguments as values or as file
paths, depending on whether a shard was given.

Checks after the fix:

- `make fmt-check`, `make lint`, and `make check` pass.
- `make test-ci` passes, 85 checks.
- With the shard files absent, `make -n test-app-shard SHARD=0 SHARDS=1` exits 0.
- `make test-app-select UI_TESTS='BrowserRemoteUITests'` passes with `EXPECTED_TESTS=1`. With `EXPECTED_TESTS=2` it
  fails with "expected 2 tests, but 1 ran".
- A real `make test-app-shard SHARD=0 SHARDS=3` logged "Selected 69 tests" and passed its first test. It was then
  cancelled. The full shards had already passed.

The row review's `adr-impact` found the commit consistent with ADR-10 and ADR-07, with no uncovered decision.
