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

### Shared machine (M1)

Another session, uniterm-74, was reproducing a flaky UI test on the same machine. The implementer's busy loops ran
from 19:53 to 20:05Z, and that session saw head failures at 20:02:27Z and 20:03:18Z. A mutation run overlapped
another of its failures, at 20:07:43Z. The coordinator sent it the load timeline. It paused its runs for the full
`make test-package`.

That session later ran ten alternating pairs under the same load. The failure followed PR #111's tab-number change:
5 failures in 10 with it, and 0 in 10 without it. So the load did not cause it.

## UTERM-046 M2

### What was built

- `HelperHandle` is a new test fixture in `ScriptHostTests`. It spawns a helper with `posix_spawn`, with every signal
  at its default, an empty mask, and only the three standard streams inherited. Its own pipe ends are close-on-exec
  from the moment they are made.
- Its reaper waits with `waitid(WEXITED|WNOWAIT)`, sets the reaped flag under the lock, and only then reaps with
  `waitpid`. Each wait retries on EINTR. `signal(_:)` returns `.reaped` once the flag is set, so no signal reaches a
  reused pid.
- A wait that finds no child throws an error that names another reaper. `finish` therefore throws, and a made-up
  status is impossible.
- `ScriptFixtures.start` returns the handle and owns the 60 s SIGTERM and 70 s SIGKILL guard. Every caller of `start`
  and `finish` moved to it, including the nine files M2 lists that built their own `Process`.
- The SIGINT tests now check the exit case, not only the status.
- The test sites M3 moves are untouched.
- Production code is unchanged.

### The Darwin finding

On Darwin 25.6, `waitid(WEXITED|WNOWAIT)` returns for a stopped child, with `CLD_STOPPED`. It keeps returning while
the child stays stopped. The fixture takes that report with a `WSTOPPED|WCONTINUED|WNOHANG` wait and waits again.
M2's reaper bullet is amended for it, as a correction of fact. The reviewer confirmed the finding with its own probe.

The implementer then checked the product's two users of the same wait:

- The exec driver's transport read a stop as the driver's exit, and sent `killpg(SIGKILL)`. A test through
  `ExecDriverChannel` failed on the unfixed code with "The driver was ended by signal 9". "Keep a stopped exec driver
  from reading as exited" fixes it with the same loop, in its own commit.
- The decoder host's `HelperProcess` kills its helper before it waits, so a stop never reads as an exit there. Its
  test passed on the unfixed code. The first report of a bug there was wrong, and `HelperProcess` is unchanged. The
  second review then found that its test could not catch the regression it named: the test's own `kill()` came first.
  It also raced the helper's hello frame. The test was dropped.

### Checks

- Mutations, each restored. Removing each of these guards failed its test:
  - the reaped-flag guard in `signal`
  - `WNOWAIT`
  - `FD_CLOEXEC` on the fixture's pipes
  - `POSIX_SPAWN_CLOEXEC_DEFAULT`
  - the default-signal and empty-mask settings
  - the stop-report wait
  - reading from the spawn on
  - the helper's own process group
  - the EINTR retry in `waitid`
- Dropping the lock in `signal` let the plain tests pass, and Thread Sanitizer reported the race.
- The `waitpid` EINTR retry has no proof, and the As built block says so.
- `testFinishReturnsForAHelperReapedBeforeItAndForOneThatEndsWhileItWaits` pins the fix, not the bug. No test
  reproduced Foundation missing an exit.
- `ScriptHostTests`, `ExecDriverChannelTests`, and `HelperClientTests`: 397 tests, 3 skipped, 0 failures.
  `make test-helper-sandbox` passed the three shipped-command tests.
- `make fmt-check`, `make lint`, `make check`: pass. `proposals.py check` reports only the row's move to history.
- The coordinator ran the full `make test-package` three times: before the review fixes, after the first round, and
  after the second. The last run, at about 22:50Z, ran 3242 tests, with 10 skipped and no failures. It holds one test
  fewer than the run before it, since the decoder host's test was dropped.

### Review

The first review found nothing blocking, and the implementer fixed all eight of its findings:

- A test could leave SIGCHLD ignored for the rest of the run, if its spawn threw. It now restores in a `defer`.
- The plain-spawn test compared whole-process descriptor lists, which another thread could disturb. It now ties each
  descriptor to the fixture.
- The EINTR retry gained a proof, and a 256 KiB helper output gained a stall test.
- The As built block retold a Decision Log reason. It now points to the entry.
- The Decision Log gained two best guesses it had missed.
- The As built block said the product sites "were reported as a bug", with no bug file. It now names the fix commit.
- The flaky entry credited three sightings, where only one recorded no live child.
- Three comments packed several ideas into one block.

A second review covered the fix round and the exec driver fix. It found the driver fix correct, with its own probe of
Darwin's `waitid`. Its findings, all fixed:

- The decoder host's new test could not catch its regression, and raced a hello frame. It was dropped.
- The EINTR test's wait for its handler had no bound. It now polls for 10 s, and fails at once if `pthread_kill`
  fails.
- The no-child test's `finish` could wait without a bound. It now returns with a failure when the helper never ends.
  The implementer left that test without the 30 s SIGKILL backstop. With `SA_NOCLDWAIT`, the kernel frees the pid at
  exit, before the fixture sets its reaped flag, so a late SIGKILL could reach a freed pid. The coordinator accepted
  that reasoning.
- The driver test sent SIGCONT unconditionally. On the failing path the driver is already reaped, so the signal could
  reach a reused pid. It now sends it only while the driver still reads as stopped.
- A Decision Log line ran to 150 columns, a flaky-entry sentence said the deadlines "now" end a helper, and three
  comments read wrong or packed ideas. All were fixed.

`adr-impact` found M2 consistent with ADR-07, ADR-08, ADR-10, ADR-13, and ADR-14, with no uncovered decision.
`proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin `other`.

### Notes

- The first implementer run stopped on an expired AWS token. The user refreshed it, and the same agent resumed.
- Three mutation runs left orphaned `cat` processes, pids 61463, 65440, and 76428, with launchd as their parent.
  Ending them needs `kill` outside the sandbox, which auto mode denied. They are left for the user.
- The implementer made a Thread Sanitizer build in `.build/swiftpm-tsan`, which git ignores.
- The new exec driver test stops and continues its driver with a raw `kill`. UTERM-046 M3, which moves test signals
  to a guarded sender, must cover or exempt it. Two test files now copy an `isStopped` check, which M3's support target
  can share.

## Row review

The row review covered the three commits from the row's base. It found the two stop-report loops alike in logic, and
M2's citation of the driver fix's subject exact. Its own probe confirmed Darwin's behavior once more. It also checked
M1's bracket on a Mac that had slept, where `ProcessInfo.systemUptime` tracked `CLOCK_UPTIME_RAW` within 83 ns.

Its findings, fixed in "Address the UTERM-046 M1-M2 row review":

- M3's signal-site list missed the driver test's SIGSTOP and SIGCONT, and the EINTR test's `pthread_kill`. M3 now
  lists both, and names `ProcessTestSupport` as the home of the shared stopped-state reader.
- The settled decision "Production keeps its rules" said the proposal has one production change. It now says one
  planned change, and names the driver fix as a bug found along the way.
- A line citation went stale after M1. It now names the `policy(_:log:sample:)` helper.
- The two stop-report loops' comments now agree.
- The no-child test sets `SA_NOCLDWAIT` process-wide for a moment. It now fails, naming them, when the test process
  has other children before it starts. A thread could still spawn one inside that window.
- `HelperProcess` gained a comment on why Darwin's stop report cannot read as an exit there. The reader kills before
  it waits.

The coordinator also reworded the M2 commit's body before this review's fixes. It had claimed that no test signal
reaches a reused pid, which holds only for the fixture's callers until M3.

`adr-impact` found the row consistent with ADR-03, ADR-05, ADR-07, ADR-08, ADR-10, ADR-11, ADR-13, ADR-14, and
ADR-15. It found no uncovered decision. A paused driver now stays connected until the pane closes or the app quits. At
quit, the main thread's wait for it stays within its 0.5 s bound.

### For the user

- The wait-without-reap loop now lives in three places: the exec transport, the fixture, and `HelperProcess`. Folding
  them into one `ProcessInspection` function, which M4 extends, would be a scope addition. The row leaves them apart.
- The no-child test's window could close fully if a separate probe process set `SA_NOCLDWAIT` instead of the test
  process. That needs a new probe executable, which would be a scope addition too.

UTERM-046 M1-M2 is finished, so its row moves to `history.md`. UTERM-046 stays `accepted`, since M3 and M4 remain.
