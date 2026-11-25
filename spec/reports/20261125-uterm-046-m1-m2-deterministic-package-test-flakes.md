# UTERM-046 M1-M2: make the logged package-test flakes deterministic

Started 2026-11-25, as the fourth row of a `/work-queue` run of `next 7`. The run's state is in
[the UTERM-045 M1 report](20261124-uterm-045-m1-launcher-change-holds-in-ci.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Move UTERM-060 M1-M3's finished row to history". The row depends on UTERM-045 M1, which this run
finished in "Record a 23rd clean launcher run and split the count into UTERM-045 M3". The row needs only the closing
rule that M1 wrote into `spec/flaky-tests.md`. No milestone has a `Live after` line.

## Best guesses from the plan

- M1: a measured share under `busyShare`, or a priority that drops after the close, is a product finding. M1's bullet
  sends it to the user before the change lands. The run records it here and in the final report, and files it as a
  bug. The test change still commits, since nothing lands before the user reviews the branch.
- Implementers run the touched package test classes. The coordinator runs a full `make test-package` before each
  milestone's commit.

## UTERM-046 M1

### What was built

- The closed-tab tests read the page through a sample derived from the live one. Only the processor time is
  replaced, by the time taken, so the page always reads as one full core. The tests no longer wait 0.3 s of real
  time.
- The derived sampler fails the test when a reading is no later than the one before it. The watch would skip such a
  reading, so an equal reading cannot let a no-signal test pass.
- The live-sample test, now `testTheLiveSampleIsInNanosecondsAndReadsAnIdlePageAsIdle`, checks its units. It
  brackets the usage reader between the POSIX process CPU clock and Foundation's uptime, with a 10 µs allowance.
  Neither reader is `CLOCK_UPTIME_RAW`, which the product uses.
- The idle pop-up test keeps live samples and its fixed 0.3 s wait. Its doc comment says that the idle guard and the
  live-tab check each stop the signal alone.
- Production code is unchanged.

### The before-change measurement

The implementer ran the old test with one busy loop per core, and on an idle machine. The machine has 14 cores.

- Over the test's 0.3 s window, the watch read 0.989 of a core idle. Under load it read 0.966 to 0.997, with up to 42
  busy processes.
- Over a 10 s window, the product's bound, it read 0.9994 to 1.000.
- At the close and at the fire, the page's spinning thread read priority 47, and Darwin did not run it in the
  background. In three loaded runs its current priority read 0 at the close, before its loop had used the core. It
  read 47 at the fire.

No share fell under half a core, and no priority dropped after the close. So the plan's product-finding route did not
trigger, and no bug was filed. The CI failure did not reproduce, so its cause stays unconfirmed. The flaky entry
records the numbers and says the test pins the fix, not the bug.

### Checks

- The implementer proved each regression bullet by mutation, then reverted each one:
  - Removing the live-tab check failed the busy-opener test and the last-live-tab test's first close.
  - Processor time in ticks, converted twice, or time taken in ticks each failed the units test with the matching
    message.
  - An equal reading failed all four derived-sample tests.
- The class passed 9 of 9 idle, with 14 and with 42 busy loops, and with 14 busy processes. The closed-tab test went
  from 0.73 s to 0.14 s.
- `make fmt-check`, `make lint`, `make check`: pass. `proposals.py check`: no findings.
- No crash report appeared during the implementer's runs.
- The coordinator ran the full `make test-package` from 20:15:41 to 20:20:25Z. 3227 tests ran, with 10 skipped and
  no failures.
- During it, `DocumentDecoderHelper` and `ImageDecoderHelper` left six abort reports, with `abort() called` and an
  `xctest` parent. The same set appears in the earlier package runs at 10:03, 10:09, and 10:16 local, and on
  2026-11-24, so the suite's own helper tests produce it.

### Review

The reviewer found no findings. It confirmed that the forward check matches the watch's strict comparison, and that
the bracket catches a 41-fold unit error in either field. `adr-impact` found M1 consistent with ADR-07 and ADR-08.
The hung-page bound stays unchanged in production. ADR-08 governs the product, not the test harness. It found no
uncovered decision. `proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin `other`.

The coordinator added the commit subject to the flaky entry's change line.

### Shared machine

Another session, uniterm-74, was reproducing a flaky UI test on the same machine. The implementer's busy loops ran
from 19:53 to 20:05Z, and that session saw head failures at 20:02:27Z and 20:03:18Z. A mutation run overlapped
another of its failures, at 20:07:43Z. The coordinator sent it the load timeline. It paused its runs for the full
`make test-package`.
