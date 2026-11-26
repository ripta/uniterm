# UTERM-044 M2: the shards run on CI

Started 2026-11-25, as the first row of a `/work-queue` run of `next 2`. Every commit is in this repo, on
`agent/petunia`. All CI times below are UTC.

## Run state

- Run base: "8< --- snip ---", on top of "Merge pull request #118 from ripta/agent/petunia-land5/uterm-046-m4". `git
  cherry upstream/main HEAD` showed only the snip, so the run needed no rebase.
- Row `UTERM-044 M2`: base is the run base. M2 is DONE. The row review is done, and the row is finished.
- Row `UTERM-060 M4`: QUEUED. Report: [20261125-uterm-060-m4-kept-evidence-on-ci.md](20261125-uterm-060-m4-kept-evidence-on-ci.md).
- No row is held or blocked. `next` skipped no row.

## UTERM-044 M2

### Plan

- No shard had failed on CI, and no run had uploaded an artifact. The run cannot push or rerun CI.
- M2 proves what the eight upstream runs since sharding landed can prove: the class listing on CI and the measured
  times.
- The bullets that need a failed shard move into a new M3, "A failed shard reruns alone on CI", by amendment.

### Evidence

The coordinator downloaded the jobs, artifacts, and logs for runs 45749818748, 45751929530, 45752629043, 45754927772,
45755641410 (both attempts), 45759466625, 45760228289, and 45762275495. It used `gh api` and `gh run view --log`.
None of these runs has an artifact. The four main pushes skipped `app` and `package` as an already-tested tree, so
the timings use the four PR runs only.

### What was done

- M2 is `DONE`. Its As built block quotes the three shard selections from 45749818748. Together they cover 33 classes
  and 206 tests once, in 10, 10, and 13 classes. Later runs add `InputRecordingProofTest` to shard 1, which makes 34
  classes and 207 tests.
- The block records the run, `package`, and per-shard setup, build, listing, and test times. `package` was the last
  job to end in every run, so it set the run's length.
- A shard job would outlast `package` at about 395 tests, from 3 × (1127.5 − 225.5) / 6.85. The range is 352 to 450.
  The suite holds 207 tests today.
- The second attempt of 45755641410 reran `package` and `ci` only. The shards kept the first attempt's times. This
  is recorded as partial evidence for M3.
- The new M3 holds "Rerunning a failed job reruns only the failed shard", plus the one-shard rerun's length. M2's third
  bullet no longer names the one-shard rerun. A Decision Log entry quotes the old text. The queue gains
  `UTERM-044 M3` after `UTERM-044 M2`.

### Checks

- `proposals.py check`: only the expected "finished row moves to history" finding.
- `make lint` and `make check`: pass.
- `make test-ci`: pass, 85 cases.

### Best guesses

- The crossover uses shard 0's overhead and rate. It is the slowest shard, so the figure is conservative.
- Test time runs from "Selected N tests" to the end of the shard step. That includes about 20 s of result handling.
- Shard 1 started late in two runs, 36 s and 2:41. Both overlapped a main push run. The block says the cap of 5
  concurrent macOS jobs probably queued it. That is not proven.
- The Design Decisions estimate "near 234 tests" assumed 15 to 17 minute shard jobs. The measured jobs take 8 to 12
  minutes. The row review amended the estimates in place. See "Row review" below.

### Bugs and flakes

- The first attempt of 45755641410 failed `package` on
  `BrowserUnsentInputTests.testEditsInASubframeMarkTheTabAndOnlyThatFrameClearsIt`. It reported "timed out waiting
  until the main frame reported its edit and its clear", at `BrowserUnsentInputTests.swift:196`, after 19.0 s. The
  rerun passed. The test already has a flaky entry. The sighting was added to it in the commit "Log a second CI
  sighting of the subframe unsent-input flake". The entry stays unresolved, with no N.

### Review

- adr-impact: no ADR touched. No uncovered decision.
- Reviewer: the numbers, the selections, the crossover arithmetic, and the split all checked out against the evidence.
  It had one finding: M1's As built pointer changed from "M2 takes" to "M2 and M3 take" with no log entry. Fixed by
  adding a sentence to the new Decision Log entry.
- The freeze report shows a hunk in UTERM-004 with origin `other`, an added ADR-14 reference line. This run did not
  make it. It is left for the user.

### Commits

- "Log a second CI sighting of the subframe unsent-input flake"
- "Prove the UI test shards on CI and split the failed-shard rerun into UTERM-044 M3"

## Row review

- adr-impact: no ADR touched. No uncovered decision.
- Reviewer finding: M2's As built block said the `package` failure's cause "was not examined". That contradicted the
  flaky sighting in the same row. Fixed. The block now names the test, its line, its 19.049 s timeout, and the "3243
  tests, 1 failure" summary.
- Reviewer finding: the three-shard Design Decision still carried the pre-measurement estimates. Fixed by an amendment
  in place, with a Decision Log entry quoting the old text. The options bullet keeps the estimates as estimates and
  gives M2's measured test time and job time. The Rationale gives the one-shard rerun as the measured shard job
  length, 8 to 12 minutes. That is 9 to 15 minutes shorter than the two-shard estimate. The rerun's own length waits
  on M3. "Near 234 tests" now reads "Near 395 tests".
- The coordinator caught two errors in the first fix pass, and the implementer corrected them. The first fix kept
  "about 11.7 minutes of tests, so its job takes about 8 to 12 minutes". It also stated a measured rerun as "about 10
  minutes shorter" than an estimate.
- Checks: `proposals.py check` shows only the expected history move. `make lint` passes. The freeze shows only
  UTERM-004's hunk with origin `other`.
