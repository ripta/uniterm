# UTERM-046: Make the Logged Package-Test Flakes Deterministic

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-22

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

Two package-test flakes fail CI on a loaded runner with no change to the code. The browser's hung-process tests give a
spinning page 0.3 s of real time and expect it to use half a core. The script fixtures miss a helper's exit and hang.
This proposal makes both deterministic. Each regression the tests name stays caught. One live-sample claim that cannot be
checked independently of load, that a real spinning page reads busy, gives way to a stronger check of the reading's
units.

## Motivation

The browser test `BrowserHungProcessTests.testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` failed on #91's CI.
Its assertion at line 294 found no signal sent: `[] is not equal to [12101]`. The test already runs the bound by hand
through `ManualHangTimer`. What it does not control is the sample. Before firing, it waits 0.3 s of real time in
`letTimePass` (`BrowserHungProcessTests.swift:183`). `ClosedProcessWatch` then signals only when the page used at least
`busyShare`, half a core, over that window (`Sources/BrowserApplet/WebContentProcess.swift:149,169`). The suspected
cause, not confirmed: on a loaded runner a spinning page can get less than half a core. The watch then rightly sends
nothing, and the test fails. Six more
places in the same class use `letTimePass` (lines 289 to 510), and one test asserts each side of `busyShare` against
live samples (lines 330 and 331).

`ScriptFixtures.finish` (`Tests/ScriptHostTests/Support.swift:214`) has hung three times, logged in
`spec/flaky-tests.md`, and each time the 120 s hang guard aborted the run. Two of the samples show it blocked in
`waitUntilExit`, and one of those shows the helper had already exited. The first sighting shows only a wait, with the
listener idle. Its
watchdog sends SIGTERM at 60 s and SIGKILL at 70 s, but only while `isRunning` reads true, so it cannot rescue an exit
Foundation missed.

The first draft of this proposal framed both as clock problems. Neither is. The browser test already injects its bound,
and the fixture waits on a process exit, not on time. The exec driver's stall test, also named in that draft, was
already fixed by "Measure stalled emits against the same emits to a reading driver", and its production bound counts
bytes, not time.

## Design Decisions (Settled)

### Production behavior does not change

Decision: production code keeps its bounds, its time sources, and its `busyShare`. A test seam replaces only what the
test supplies, never the rule the production code applies.

Rationale: the hung-process bound and the busy-share rule are how a hung page stays contained, per ADR-07. A test
shortcut that weakened them would trade a flaky test for a weaker product.

### No new waits on the product's main thread

Decision: making a test deterministic never adds a wait to the product's main thread. A test's own awaited polls are not
covered by this decision.

Rationale: ADR-08 says the main thread never waits on work whose duration uniterm does not bound. It governs the
product, not the test harness.

### How the test waits for the process to end

`waitUntilGone` polls for up to 15 s. The WebContent process is not the test's child, so `waitpid` cannot see it.

- **Keep the poll.** It already waits for an event, with a deadline.
- **Wait on the exit event.** `DispatchSource.makeProcessSource` with an `.exit` event mask reports the end of any
  process the test can see.

Decision: keep the poll.

Rationale: the poll already ends on the event, `kill(pid, 0)` reporting `ESRCH`, under a 15 s deadline. No logged failure
came from it. The failure logged at line 178 followed from no signal being sent. An exit source would add a kqueue
source and a check for a process that ended before the source was armed, and it protects against no named failure.

### How the fixture waits for its helper

- **The fixture reaps its own helper.** `start` spawns the helper with `posix_spawn`, and one thread per helper waits on
  it with `waitpid`. Signals go only before that reap, and a process id cannot be reused until its parent reaps it, so
  the watchdog can never signal another process. `HelperHost`'s `HelperProcess` and the exec driver's transport already
  work this way. `start` then returns the fixture's own handle instead of a `Process`, so every caller moves to it,
  including the callers that read `isRunning`, `terminationReason`, or the process id today.
- **A termination handler.** `finish` resumes when Foundation's `terminationHandler` fires, after reading both pipes.
  `start` already sets one for `onExit` callers, so `finish` must chain to it. It relies on Foundation's exit report,
  which is the mechanism the second sighting suggests missed an exit.
- **`waitid` with `WNOWAIT` beside `Process`.** `finish` sees the exit without reaping it and takes the status from the
  `siginfo`. Foundation stays the only reaper. The watchdog and the callers keep reading `Process`.
- **`waitpid` beside `Process`.** Foundation also reaps the children it launches. With two reapers on one process id,
  only one gets the status: the other gets `ECHILD`, or leaves `Process` with an undefined state that the watchdog's
  `isRunning` gate then reads.

Decision: the fixture reaps its own helper. `start` spawns with `posix_spawn`, a thread per helper reaps it with
`waitpid`, and `start` returns the fixture's own handle. Every caller of `start` and `finish` moves to that handle,
including every caller that builds its own `Process` and hands it to `finish` today.

Rationale: it is the only option that holds under both readings of the second sighting. The hang guard's `ps` listing
shows zombies, so "no child of `xctest` alive" means the helper had already been reaped. Either Foundation reaped it and
never woke `waitUntilExit`, or another reaper in the same process took it. Only a fixture that is the sole reaper of its
own child is immune to both. It is also the only option that keeps the watchdog off a freed process id. With
`isRunning` stuck true after a reap, today's watchdog sends SIGTERM and SIGKILL to an id the system may have handed to
another process. The termination handler and `waitid` both keep that `isRunning` gate, so neither can meet M2's check
that the watchdog never signals an exited process. Under a foreign reaper, `waitid` also falls back to reading
`terminationStatus` on a task that reads as running, which raises instead of returning.

Leaves undone: test code in `ScriptHostTests` that waits on Foundation's exit report outside the fixture keeps doing so.
These are `DeclaredFileRunTests.start`, which polls `isRunning` and has its own `isRunning` watchdog, `ReplSupport`, the
`waitUntilExit` in `ScriptBindingTests`, `CommandHelperSandboxTests`, and `skipUnlessSystemIntegrityIsOn`, the
`isRunning` polls and the two `waitUntilExit` calls in `ControllerRunTests`, `ScriptReplTests`' own helper run, and the
`ScriptGrantTests` source session. None has a logged failure. See the audit decision below.

### How far the audit goes

- **Logged flakes only.** The two above, and each new entry as it appears.
- **Every real-time wait in the package tests.** Classify each as a wait for an event, a deadline guard, or a real
  sleep, and fix every sleep that stands in for an event. The calls cluster in the terminal session integration tests,
  the exec pane tests, the exec driver channel tests, and the Markdown viewer tests. This is an addition, and it needs
  its own milestone.
- **Same mechanisms elsewhere.** Replace every other `waitUntilExit` in the package tests, about 15 sites in 7 targets,
  and every other live CPU-share window. This is an addition, and it needs its own milestone.
- **The fixture's neighbors.** After M2 holds on CI, move the other Foundation exit waits in `ScriptHostTests` that the
  fixture decision leaves undone. This is an addition.

Decision: logged flakes only. New flakes go through `spec/flaky-tests.md`'s Rule as they appear.

Rationale: it is complete within the proposal's problem, the two logged flakes. Every other option is an addition with
no logged failure behind it. The CPU-share half of "same mechanisms elsewhere" names nothing: no other test uses
`usage`, `busyShare`, or `letTimePass`. Its `waitUntilExit` sites run on test threads rather than dispatch workers, and
none has failed. The real-time wait audit targets a different mechanism, sleeps that stand in for events. The fixture's
neighbors share the fixture's suspected cause, so they are the strongest candidate if a sighting names one of them.

### How the closed-tab tests get their sample

- **Supply a busy sample end to end.** The closed-tab tests pass a sample through `policy.process.sample` that reads as
  busy. They keep the real signal and the real process exit. `ClosedProcessWatch`'s decision is already pinned by its
  own tests with supplied samples. Leaves undone: the live-sample test, which reads real CPU use by design.
- **Make the live window load-independent.** `letTimePass` stops spinning on the main thread, and the test fires only
  once its own sample reads busy. Every test keeps live samples. Leaves undone: a runner loaded by other processes can
  still starve the page.
- **Both.** Closed-tab tests supply their sample, and the one live-sample test waits until it reads busy. Leaves undone:
  the live-sample test can still be starved by outside load, as in the option above.
- **Derived samples plus a units bracket.** The closed-tab tests wrap the live sampler. It keeps the live reading's start
  time, its nil for a gone process, and its time taken, and replaces only the processor time: equal to the elapsed time
  for busy, frozen for idle. The live-sample test proves its units against independent readers instead of a timed
  window. Leaves undone: no test shows that a real spinning page reads busy under real scheduling.

Whichever option wins, `testClosingAnIdlePopUpSignalsNothing` keeps an idle sample, live or supplied.

Decision: derived samples plus a units bracket. The closed-tab tests that need a spinning page use a sampler wrapped
around the live one, which replaces only the processor time, and they drop `letTimePass`.
`testClosingAnIdlePopUpSignalsNothing` keeps its live sample, since load cannot make an idle page read busy. The
live-sample test keeps its idle side live. Its busy side becomes a bracket: an independent reading of the test's own
processor time and uptime before and after `WebContentProcess.usage(getpid())`, with the middle reading between them.

Rationale: it is the only option in which every check is independent of load. The watch averages over the whole span
from close to fire, so a test that waits for its own window to read busy does not bound that average, and a starved
page still fails. Sampling the live test again until it reads busy is a retry, which `spec/flaky-tests.md`'s Rule bans,
and a missed conversion then fails only at a deadline that cannot tell it from starvation. Supplying a busy sample alone
leaves the live-sample test exposed to the same load. A derived sample keeps the real process identity, the real nil for
a gone process, the real signal, and the real exit. It also makes the no-signal tests reach the live-tab check, which a
starved sample today lets them skip.

Dissent left standing: the option drops the live-sample test's claim that a real spinning page reads at least
`busyShare`. That reads as the weaker assertion `spec/flaky-tests.md`'s Rule bans. Answer: the regression the test names
is a units error, about 41 times off. The timed window caught a single wrong field too, but only when the runner gave the
page enough of a core. The bracket catches it in either field, or in both with their ratio intact, on every run. The
claim dropped is the part that depended on the runner's load. M1's measurement covers what it told us about the
product.

## Design Decisions (Open)

None.

## Risks

- **A supplied sample hides a broken live reading** — likelihood: low, impact: medium.
  Mitigation: the live-sample test brackets the live reading against independent readers of processor time and uptime,
  so a reader in the wrong units still fails a test. The idle pop-up test keeps a live sample of a closed tab.
- **The closed process reads idle in the product too** — likelihood: low, impact: medium.
  The cause of the logged failure is not confirmed. WebKit may lower a content process's priority once it has no view.
  If so, a spinning closed tab can read under `busyShare` on a loaded machine and the product never ends it. Derived
  samples then hide that from CI. The likelihood is rated on the test-side explanation, a 0.3 s window shared with a
  main thread that spins, which is the stronger one. Mitigation: M1 measures the share of a real closed spinning tab
  under load and idle before the change, and a reading under `busyShare` in either run, or a priority drop after the
  close, goes to the user.
- **A spawned helper inherits the test process's signal state** — likelihood: medium, impact: medium.
  `posix_spawn` keeps ignored signals and the spawning thread's mask, where Foundation resets them. A REPL test ignores
  SIGPIPE for the whole test process, so helpers spawned after it would behave by test order. Mitigation: M2 starts the
  helper with every signal at its default and an empty mask, as the exec driver's transport does.
- **A new wait mechanism misses an exit the old one saw** — likelihood: low, impact: low.
  Mitigation: the fixture's change is proven against a helper that exits at once and one that exits after a delay.

## Milestones

### M1: The browser hung-process tests

**Status:** NOT STARTED

- The closed-tab tests pass on a runner whose cores are all busy with other work
- The live-sample test fails when either time field of the live reading is in the wrong units. Its bracket allows the
  difference between independent readers, set from a recorded measurement and far below a 41-fold error. The uptime side
  uses a reader other than `CLOCK_UPTIME_RAW`, which the product uses
- The derived busy sample's time taken always moves forward between the close and the fire, so an equal reading fails
  loudly instead of skipping the signal
- Before the change, a run of `testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` with one busy loop per core,
  and one on an idle machine, log the watch's share and the closed process's scheduling state at the close and at the
  fire: its priority from `proc_pidinfo` and whether Darwin runs it in the background. The
  flake entry records both. A share under `busyShare` in either run, or a priority that drops after the close, goes to
  the user as a product finding before the change lands
- A supplied busy sample reaches the live-tab check: the busy-opener test and the first close of the last-live-tab test
  fail when that check is removed
- `testClosingAnIdlePopUpSignalsNothing`'s doc comment says that the idle guard and the live-tab check each stop the
  signal alone, since its opener shares the process
- `testClosingAnIdlePopUpSignalsNothing` still sees an idle page and signals nothing, and its wait ends on a bound,
  never on a busy reading
- The closed-tab test's entry in `spec/flaky-tests.md` records the change, says the test pins the fix and not the bug,
  and stays under Potential until it meets the closing rule in the `spec/flaky-tests.md` Rule section
- Production's `busyShare`, bound, and time sources are unchanged

### M2: The script fixture's helper exit

**Status:** NOT STARTED

- `ScriptFixtures.finish` returns once its helper exits, without `waitUntilExit`, including for a helper that exited
  before `finish` was called
- Callers that observe a helper's exit, as `onExit` callers do today, still see it
- Every caller of `start` and `finish` runs its helper through the fixture's exit path. That includes every caller that
  builds its own `Process` and hands it to `finish` today, such as `ScriptRunCommandTests.runRaw`,
  `ScriptLintCommandTests`, `ScriptOpenRunTests`, `ScriptAskRunTests`, `ControllerRunTests`, `ControllerConsentTests`,
  `CommandHelperSandboxTests`, `DeclaredFileRunTests.run`, and the fake-app run in `DeclaredFileProtocolTests`. Their own
  `isRunning` watchdogs go with it
- The spawned helper inherits only its standard input, output, and error, so a write end leaked into one helper never
  holds another fixture's pipe open. It still gets the caller's input pipe, environment, and working directory
- `onExit` runs once, from the thread that reaps the helper
- A signal goes out only while the reaped flag, read under the same lock the reaper sets it under, says the helper has
  not been reaped. Each wait retries on `EINTR`
- The regression test says that it pins the fix and not the bug, since no test reproduced Foundation missing an exit
- A test can still tell a helper's exit from its death by a signal
- The watchdog never signals a helper that has been reaped. The reaper waits with `waitid` and `WNOWAIT`, sets the reaped
  flag under the lock, and only then reaps with `waitpid`
- Callers signal a helper through the fixture's handle, never with a raw `kill` on its process id
- The fixture spawns any executable with any argument list and environment, and `start` is a thin wrapper on it
- The helper starts with every signal at its default and an empty signal mask, whatever the test process has set
- The fixture marks its pipe ends close-on-exec right after creating them and before it spawns or returns, as the exec
  driver's transport does, so no other spawner in the test process inherits them.
  `finish` states what it does when the helper is reaped but a pipe stays open
- A wait that returns `ECHILD` marks the helper reaped and fails the test with an error that names another reaper. It
  never reports a made-up status
- The handle reports a normal exit and a death by signal apart, as `terminationReason` does today
- The `ScriptFixtures.finish` entry in `spec/flaky-tests.md` records the change, says which of its sightings it
  explains, and stays under Potential until it meets the closing rule in the `spec/flaky-tests.md` Rule section

## Decision Log

- 2026-11-21: Filed during a landing run in which two package-test failures cost CI reruns. The user asked whether
  this flakiness could be fixed for the future.
- 2026-11-21: Re-scoped from "inject clocks into timing-sensitive package tests". A design review found neither
  motivating test was a clock problem. The exec stall test was already fixed, and the browser test already injects its
  bound. The user chose to re-scope around the actual flake mechanisms.
- 2026-11-22: Review start: 2 milestones, 2 settled decisions, 2 risks, no `**Live after:**` lines or row gates, and no
  out-of-scope statements beyond the audit question's addition label. The user asked for an autonomous review of the
  four open questions. The proposal stood at the commit "Route UTERM-046's final review checks into its milestones".
- 2026-11-22: The browser tests keep polling for the content process to end. The poll already ends on the event, with
  a deadline, and no logged failure came from it. (autonomous)
- 2026-11-22: The script fixture spawns and reaps its own helper, and every caller of `start` and `finish` moves to the
  fixture's handle. It is the only option immune both to Foundation missing an exit and to another reaper, and the
  only one that keeps the watchdog off a freed process id. (autonomous)
- 2026-11-22: The audit covers the two logged flakes only. Every wider audit is an addition with no logged failure
  behind it. (autonomous)
- 2026-11-22: The closed-tab tests derive their sample from the live one, replacing only the processor time, and the
  live-sample test proves its units with a bracket against independent readers. Every check is then independent of load.
  The live claim that a real spinning page reads busy is dropped. (autonomous)
- 2026-11-22: Added the risk that a closed process reads idle in the product too, with a measurement in M1. (autonomous)
- 2026-11-22: The Summary now says the live-sample claim that a real spinning page reads busy gives way to a units
  check. M1's product measurement escalates a low share from the loaded run as well as the idle one. (autonomous)
- 2026-11-22: Added the risk that a spawned helper inherits the test process's signal state, mitigated in M2.
  (autonomous)
- 2026-11-22: M1's and M2's flaky-entry checks now close an entry by the closing rule in the `spec/flaky-tests.md` Rule
  section, the rule UTERM-045 sets for every entry, instead of an unstated count of CI runs. (autonomous)
- 2026-11-22: Review gate: kept all. Derived samples plus a units bracket stand, and the Summary keeps its reworded
  claim. No decision gets an ADR. Status set to accepted.

## References

- ADR-07: Failure isolation
- ADR-08: UI responsiveness
- `spec/flaky-tests.md`
- UTERM-045, whose closing rule in the `spec/flaky-tests.md` Rule section decides when this proposal's entries move to
  Fixed
