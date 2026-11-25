# UTERM-060 M1-M3: keep the evidence of where a UI test's input went

Started 2026-11-25, as the third row of a `/work-queue` run of `next 7`. The run's state is in
[the UTERM-045 M1 report](20261124-uterm-045-m1-launcher-change-holds-in-ci.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Move UTERM-044 M1's finished row to history". The row depends on UTERM-044 M1, which this run
finished in "Shard CI's UI tests across three macOS runners" and "Run a UI test selection without recursive make". No
milestone has a `Live after` line.

## Best guesses from the plan

- M1's CI-only checks split into a new UTERM-060 M4 by amendment, since the run never pushes. M4 takes these checks:
  - a failed CI job uploads the kept log
  - a runner's kept log holds the event lines
  - `log show`'s time on a failed CI suite
  - the upload at the job's time limit
  - each failing shard's upload carrying its log

  M2's grant check on the CI image's macOS joins M4 when M2 runs. The workflow edits that serve these checks still land
  in M1. If this is wrong, M1 stays `IN PROGRESS` until a pushed run.
- M1 passes the kept-log path to `scripts/run-ui-tests.sh` explicitly from the Makefile. The runner logs under its own
  subsystem, apart from `dev.uniterm.app`.
- M2's "a UI test finds the records" is checked by `log show` over the test's window after the run. The sandboxed
  runner cannot read the log store.
- M2: if probing the tap raises a privacy prompt, the recorder uses the `nextEvent` override alone, and the As built
  block records the prompt.
- Implementers run targeted UI tests. The coordinator runs the full suites after M1 and M2, since both change the UI
  test base class.

## UTERM-060 M1

### What was built

- `scripts/run-ui-tests.sh` records the start time once it holds the screen lock, and writes it to
  `ui-test-start-time.txt`. After a failed run it calls `scripts/collect-ui-test-log.sh`.
- `scripts/collect-ui-test-log.sh` is the one place that takes the log. It runs `log show` for
  `process == 'testmanagerd' OR subsystem == 'dev.uniterm.uitests'` from the start time, and gzips the result. It
  says when the log has no event lines, and when `log show` failed.
- The Makefile passes the kept-log path as `UNITERM_UI_KEPT_LOG` for `test-app`, `test-app-select`, and
  `test-app-shard`. Each shard gets its own file.
- `UnitermUITestCase` logs test start and end marks from `invokeTest()`, and issue marks from `record(_:)`. It logs
  the frontmost app at start, and each activation change from an observer on a background queue. A failing test keeps
  the frontmost record as an attachment with `.deleteOnSuccess`.
- `ci.yml`: the job limit rises from 45 to 50 minutes, and the test step gets a 38-minute limit. A follow-up step
  takes the kept log through the same script when the test step did not finish. The upload runs on failure or
  cancellation, and carries the shard's kept log.
- M1 is `DONE`. The new M4, "The kept evidence on CI", takes the CI-only checks. The queue gains a `UTERM-060 M4` row.

### Checks

- `make fmt-check`, `make lint`, `make check`: pass. `make test-ci`: pass, 85 checks.
- The coordinator ran the full `make test-app`: 206 tests passed in 16 minutes. The run wrote no kept log. No crash
  report appeared during it. The `xctest` reports at 04:01 and 04:14 came from `make test-ci`'s watchdog fixture.
- The implementer's local proofs are in M1's As built block. The Xcode version is 26.6. A deliberately failing
  throwaway test left a kept log with its marks and 318 `testmanagerd` lines. `log show` over 25 minutes took 2.7 s.
  A frontmost change was logged within 5 ms during `typeText`. A test cut off by the allowance kept its start mark and
  got no issue mark.
- The coordinator checked the attachment proofs with `xcresulttool export attachments`. The failing bundle holds
  `frontmost-record`. The passing bundle holds no frontmost attachment.

### Review

The implementer needed four rounds to finish the milestone. Its first report left the workflow, the compression, the
attachment, and every local proof undone. Its second deferred two checks to "manual testing", which the plan did not
allow. Its third stopped, citing its token budget, and was sent back to finish. Each round was sent back with the
missing items.

The coordinator also found these, and all were fixed:

- The workflow copied the `log show` logic into YAML. It now calls the shared script.
- A 40-minute step limit inside a 45-minute job left no time for setup, collection, and upload.
- The passing-run proof used a selection with no tests, which the zero-test check fails.
- The full suite showed that every passing test attached `frontmost-record.txt`. `testRun?.hasSucceeded` reads false
  during teardown. The attachment now uses `.deleteOnSuccess`.
- The As built block used bold labels, misstated the timeout arithmetic, and overclaimed two proofs. Two reworded
  bullets were not quoted in the Decision Log.

The reviewer found all M1 bullets met. It raised three findings:

- A timeout comment misplaced the build. Fixed.
- Two comment blocks needed paragraph breaks. Fixed.
- A risk amendment lacked "see Decision Log". Dismissed: that text predates this run, and this diff does not touch
  it.

`adr-impact` found the diff consistent with ADR-08, since the frontmost observer runs off the main thread. It found no
uncovered decision. `proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin `other`.
