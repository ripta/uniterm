# UTERM-046: Make the Logged Package-Test Flakes Deterministic

**Status:** designing
**Created:** 2026-11-21
**Updated:** 2026-11-23

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

Two package-test flakes fail CI on a loaded runner with no change to the code. The browser's hung-process tests give a
spinning page 0.3 s of real time and expect it to use half a core. The script fixtures miss a helper's exit and hang.
This proposal makes both deterministic. Each regression the tests name stays caught. One live-sample claim that cannot be
checked independently of load, that a real spinning page reads busy, gives way to a stronger check of the reading's
units. It also closes the reused-id race in every package test that signals a process by its id. A test's own helper
signals through the fixture's handle. A process the product, libghostty, or WebKit reaps is signalled by its audit
token where the system gives one, and by a start-time check where it does not. The product's two check-then-signal
sites, the content-process kill and the REPL helper reaper, move to the same token signal.

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

### Production keeps its rules

Decision: production code keeps its bounds, its time sources, and its `busyShare`. A test seam replaces only what the
test supplies, never the rule the production code applies. The one production change is how two kills name their
target. `WebContentProcess.kill` and ScriptHost's `ProcessReaper` signal by the process's audit token. Amended
2026-11-23; see Decision Log.

Rationale: the hung-process bound and the busy-share rule are how a hung page stays contained, per ADR-07. A test
shortcut that weakened them would trade a flaky test for a weaker product. Signalling by token keeps every rule. It
only stops a kill from reaching a process that took a freed pid.

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

Leaves undone: test code in `ScriptHostTests` that waits on Foundation's exit report outside the fixture, and never
signals its helper, keeps doing so. These are the `waitUntilExit` in `ScriptBindingTests`, `CommandHelperSandboxTests`,
and `skipUnlessSystemIntegrityIsOn`, and the two `waitUntilExit` calls in `ControllerRunTests`. None has a logged
failure. See the audit decision below. The sites that signal their helper by process
id move to the fixture's handle in M3. Amended 2026-11-23; see Decision Log.

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

Decision: logged flakes only, plus every package test that signals a process by its id. New flakes go through
`spec/flaky-tests.md`'s Rule as they appear. Amended 2026-11-23; see Decision Log.

Rationale: the logged-flakes half is complete within the proposal's problem. The signalling tests are an addition the
user chose. See below. Every other option is an addition with no logged failure behind it. The CPU-share half of "same
mechanisms elsewhere" names nothing: no other test uses
`usage`, `busyShare`, or `letTimePass`. Its `waitUntilExit` sites run on test threads rather than dispatch workers, and
none has failed. The real-time wait audit targets a different mechanism, sleeps that stand in for events. The fixture's
neighbors share the fixture's suspected cause, so they are the strongest candidate if a sighting names one of them.

The neighbors that signal are a different failure, not a flake. Each one checks `isRunning`, then signals the process
id. Once the helper is reaped, that id is free for reuse. So a test can kill an unrelated process of the same user. That
needs no logged sighting to matter. For a helper the test spawns, only the fixture's handle closes it. See
`spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md`. `PresentationTests` and `SenderWatcherTests`
spawn their own processes in `WindowKitTests`, so the fixture moves to `ScriptTestSupport`, which both test targets
already import. The same race sits in tests that signal a process something else reaps. Those are in the open
question below.

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

### How a test signals a process it does not reap

The fixture closes the race because it is its helper's only reaper. These tests signal a process that something else
reaps, so no test handle can hold the reap:

- **Reaped by other code in the test process.** `ExecPaneTests.swift:815` probes the driver with `kill(pid, 0)`, then
  sends SIGKILL. The product's exec transport spawns the driver in the test process and reaps it. Its reaped-flag
  signal is private, and the channel exposes only the pid. libghostty spawns `login(1)` as a child of the test process,
  and reaps it itself.
- **Reaped by launchd after a reparent.** `ExecDriverChannelTests.swift:451` kills the driver's background child, whose
  pid the driver writes to a file. `TerminalSessionIntegrationTests.swift:93`, `:756`, and `:762` kill the tree under
  `login`: the shell and its `sleep`, which launchd adopts once `login` exits on SIGHUP. `tearDown` and the defer at
  `:755` also kill `login` itself after `close()` returned. libghostty has reaped it by then, so that SIGKILL goes to a
  freed pid on every run.
- **WebKit content processes.** `WebContent.kill` in `BrowserRecoveryTests` and `MarkdownRig.swift:172` signal the pid
  that `_webProcessIdentifier` names. The `if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) }` defers in
  `BrowserRecoveryTests` and `BrowserHungProcessTests` check, then kill. `BrowserHungProcessTests.swift:218` passes the
  product's chosen pid to a real `kill`.

Making the test the parent does not help. It already is the parent of the driver and of `login`, but other code in the
same process holds the reap. macOS has no subreaper, so the test cannot take the reap of reparented or WebKit
processes either.

Each option is only as good as the moment the test learns the pid. Each site checks what it learned then. The
grandchild's parent is the driver. The terminal tree and its identities are read in one pass, before `close()`. A
WebContent pid's path carries `com.apple.WebKit.WebContent`, as `MarkdownRig.swift:166` already checks. The driver's
pid is read only while the channel is connected. The injected `signal` closure in `BrowserHungProcessTests` looks up
the identity the test learned, and refuses a pid it has none for.

- **An audit-token sender.** When the test learns a pid, it reads the process's audit token through
  `task_name_for_pid` and `task_info(TASK_AUDIT_TOKEN)`. Every later signal goes through
  `proc_signal_with_audittoken` (`libproc.h:132`). The kernel signals only the process whose pid version matches the
  token. It returns ESRCH for any other process, a zombie included. Design-critic probes on 2026-11-23 confirmed that
  for a child and for a reparented `sleep`. A token read for launchd, which runs as root, failed. Where no token can be
  read, the sender falls back to the identity check below. Each site states which path it expects, and fails the test
  when it gets the other. Leaves undone: a site on the fallback keeps that option's window. `login` is setuid root and
  likely refuses a token. WebContent may too, though it runs as the user. Neither was tested. The call has no
  documentation beyond its header. An OS release that drops it fails at link time.
- **An identity-checked sender.** The test records the pid and its start time to the microsecond, from
  `sysctl(KERN_PROC_PID)`'s `p_starttime`. `proc_pidinfo` refuses `login`. `ProcessInspection.startTime` keeps seconds
  only, so `ProcessInspection` gains a microsecond reader. The sender reads the start time again right before the
  signal, and signals only when it matches. Leaves undone: a reuse between that read and the signal. macOS hands out
  pids in order, so that needs about 99,900 pid allocations inside the window.
- **An exit watch.** The test registers a kqueue `EVFILT_PROC` `NOTE_EXIT` filter when it learns the pid. The sender
  signals only when no exit event has arrived. Leaves undone: the same window as the identity check, between the event
  check and the signal. It gains nothing over that option, and adds a kqueue per process.
- **Stop signalling.** Each site that already waits for the process to end fails the test instead of killing it.
  Leaves undone: a failed test leaves its process running. That breaks the terminal tests' rule that no test leaves an
  orphan, and the browser tests' cleanup of a page that keeps spinning.
- **Signal through the owner.** The product and libghostty gain a call that signals under their reaper's lock. Leaves
  undone: WebKit content processes and reparented processes have no owner in reach. It adds public product calls whose
  only users are tests, which `practices/testing.md` rules out.

`HelperProcess.kill`, used in `HelperClientTests`, already signals under its reaper's lock, so it needs nothing.
`ProcessInspectionTests` signals a child before its own `waitpid`, so it needs nothing either.
`RemoteClientWatcherTests` signals `sh` before its own `waitpid`, so that signal needs nothing. Its client is below.

The product's `WebContentProcess.kill` checks a pid's path, then signals it. ScriptHost's `ProcessReaper`
(`ScriptRepl.swift:58-73`) checks a `ProcessIdentity` whose start time has one-second resolution, then sends
`Darwin.kill`. Each is the same check-then-signal window in production code.

`RemoteClientWatcherTests.swift:255` spawns `sh`, which forks a 30 s client. `tearDown` kills only `sh`, so the client
outlives the test for up to 30 s. At `tearDown` the client is still `sh`'s child, since `sh` waits for it.

Decision: the token read, the token signal, and the microsecond start time are public calls in `ProcessInspection`.
That product library has no dependencies, and already reads identity through sysctl for setuid-root processes. The
calls take and return the existing `AuditToken`. It moves from `FileRouting` into `ProcessInspection`, and
`FileRouting` depends on `ProcessInspection`. A new test-support target, `ProcessTestSupport`, depends only on
`ProcessInspection`. It holds the per-site sender. A site that cannot read a token falls back to the identity check.
Each site states which path it expects. `WebContentProcess` and the REPL channel record a token with the identity,
and the kills signal by it. The REPL channel's token is the one the kernel gave its connection at admission.
`WebContentProcess.kill` keeps its path check on both paths. With a token, it then signals by the token. With none,
it signals as today, so a hung page is still ended. `ProcessReaper` keeps its identity check when it has no token.
`RemoteClientWatcherTests` spawns `sh` in its own process group, and sends `killpg` before its own `waitpid`. Amended
2026-11-23; see Decision Log.

Rationale: the token is the only option that closes the window outright, for every target that gives one. The
identity check narrows the window but leaves it. The exit watch gains nothing over the identity check. Stopping the
signals leaves orphans. Signalling through the owner needs product calls only tests use. It still cannot reach WebKit
or reparented processes. The fallback keeps the identity check's window only where the system refuses a token. A site
that lands on the wrong path fails its test, so a change in what the system allows shows up at once.

`ProcessInspection` serves every site and the product. A test-only home would need four more test targets to link
ScriptHost, and the product could not import it. The expected-path rule is test policy, so it stays in a test target.
The product's two kills have the same race as the tests, and the same call closes it there. A stale pid either fails
the path check, or passes it and gets ESRCH from the token. One token type keeps a peer's token, read from
`LOCAL_PEERTOKEN`, usable as a signal target with no conversion. The group signal closes the `RemoteClientWatcherTests`
window too. The unreaped `sh` holds the group id, so no other process can take it.

Leaves undone: `login`, and WebContent if it refuses a token, keep the identity check's window. M3 and M4 record which
path each site took. The call has no documentation beyond `libproc.h`. An OS release that drops it fails at link time,
not silently.

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
- **A group-wide signal weakens the controller signal tests** — likelihood: low, impact: medium.
  The exec driver's transport spawns into its own process group and signals it with `killpg`. A fixture that copies it
  would let `ControllerRunTests`' signal-relay tests pass for a command that forks and never relays SIGINT. Mitigation:
  M2 checks that the handle signals the helper's own process, never its group.
- **The audit-token call changes or goes away** — likelihood: low, impact: medium.
  `proc_signal_with_audittoken` has no documentation beyond `libproc.h`. A release could drop it, or refuse tokens for
  processes it allows today. Mitigation: a dropped call fails at link time. A refused token sends a site to the
  fallback, and each site fails its test when it gets a path it did not expect. The product's two kills keep their
  checks when they read no token.
- **WebContent refuses a token, and the product silently stays on its path check** — likelihood: low, impact: low.
  The product then keeps today's window, and no user sees a difference. Mitigation: a BrowserApplet test fails when a
  real view's content process gives no token. The product logs a failed token read.
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

Amended 2026-11-23; see Decision Log.

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
- Callers of `start` and `finish` signal a helper through the fixture's handle, never with a raw `kill` on its process
  id
- The tests among those callers that send SIGINT, such as the Ctrl-C tests in `ScriptLimitsTests`,
  `ScriptAskScriptTests`, and `ScriptAskRunTests`, still deliver it and still see the helper's exit
- The fixture spawns any executable with any argument list and environment, and `start` is a thin wrapper on it
- The spawn takes any file handle for each standard stream: a pipe the caller owns, a pty end, or the null device
- The handle reports whether the helper has exited, and its status, without waiting. It sends any signal number
- The handle signals the helper's own process, never its process group
- The handle sends with `signal(_:)`, and has no method named `kill`, `terminate`, or `interrupt`
- A helper stopped by SIGSTOP still reads as running, and SIGCONT and SIGKILL still reach it
- The 60 s and 70 s hang guard belongs to `start`. The generic spawn takes each caller's own deadline and signal
- The helper starts with every signal at its default and an empty signal mask, whatever the test process has set
- The fixture marks its pipe ends close-on-exec right after creating them and before it spawns or returns, as the exec
  driver's transport does, so no other spawner in the test process inherits them.
  `finish` states what it does when the helper is reaped but a pipe stays open
- A wait that returns `ECHILD` marks the helper reaped and fails the test with an error that names another reaper. It
  never reports a made-up status
- The handle reports a normal exit and a death by signal apart, as `terminationReason` does today
- The `ScriptFixtures.finish` entry in `spec/flaky-tests.md` records the change, says which of its sightings it
  explains, and stays under Potential until it meets the closing rule in the `spec/flaky-tests.md` Rule section

### M3: Every test signal goes through a guarded sender

**Status:** NOT STARTED

Amended 2026-11-23; see Decision Log.

Starts after M2 and M4. It moves sites onto M2's handle, and onto the token calls M4 adds.

No package test signals a process by an id that the process may no longer hold.

- These sites spawn through the fixture and signal only through its handle:
  - `DeclaredFileRunTests.start`, its watchdog, and the teardowns of the tests that use it
  - `ReplSupport`'s session, on pipes and on a pty, with its watchdogs, teardown, and interrupt
  - `ScriptReplTests`' own helper run, and its kill of a REPL session
  - `ControllerRunTests`' own `start`, its two inline runs, and the stand-in instance in its launch-cleanup test
  - `ScriptReplGrantTests`' `/bin/sleep` stand-ins for a second session
  - `ScriptGrantTests`' source session, and `SocketRelay.stop`
  - `ScriptReplLimitsTests`' teardown, its stop of a session, and its reaper's kill closure
  - `ControllerConsentTests`' kills of an admitted run
  - `PresentationTests`' helper run and its watchdog
  - `SenderWatcherTests`' `/bin/sleep`
- `ControllerConsentTests.run` hands the test its handle before it waits. Each kill checks that the admitted pid equals
  that handle's pid, and fails the test otherwise
- The reaper's kill closure in `ScriptReplLimitsTests` finds the test's handle for the pid under a lock, and signals
  through it. A pid with no handle is recorded and not signalled
- `ReplProcess`'s interrupt is renamed, so the search below finds no `.interrupt()`
- The fixture lives in `ScriptTestSupport`. The `start` wrapper stays in `ScriptHostTests`, since its scripts come from
  that target's bundle
- The sites in "How a test signals a process it does not reap" signal only through the sender in
  `ProcessTestSupport`, which depends only on `ProcessInspection`
- Where no token can be read, the sender compares the start time to the microsecond right before the signal. Each site
  states whether it expects a token or the fallback. A site fails the test when it gets the other
- A token signal that returns ESRCH never falls back to the pid. The fallback is chosen only when no token was read at
  the time the test learned the pid
- Each site checks the pid when it learns it. The grandchild's parent is the driver. Each terminal tree member's token
  is read in one pass before `close()`, and its parent is the member before it. A WebContent pid's path carries
  `com.apple.WebKit.WebContent`. The driver's pid is read while its channel is connected
- The terminal teardowns signal `login` only through its recorded identity, so a `login` that `close()` already ended
  gets no signal
- The injected `signal` closure in `BrowserHungProcessTests` forwards the identity the product read to the sender, and
  records the pid. It signals nothing for an identity it was not given
- `RemoteClientWatcherTests` spawns `sh` in its own process group. `tearDown` sends `killpg` before its own `waitpid`,
  so the client `sh` forks ends with it
- The As built block records which path each site took, and whether `login` gave a token
- No package test sends a signal with a raw `kill` on a process id, or with `Process.terminate` or `interrupt`
- Signal 0 probes are exempt. So is the relay's forked child, which its parent never reaps. So are tests that signal
  their own child before their own `waitpid`, and `HelperProcess.kill`, which signals under its reaper's lock
- `ReplProcess` and every moved site expose the fixture's handle and no `Process`, so `.terminate()` on them does not
  compile
- A search of `Tests/` for `kill(`, `.terminate()`, and `.interrupt()` finds only the fixture, the sender, the
  exemptions above, the group signal in `RemoteClientWatcherTests`, and product kill calls under test that send
  through an injected sender
- Each moved site keeps its hang guard: a helper that never exits is still killed at that site's own deadline
- The tests that send SIGINT, SIGSTOP, or SIGCONT through a moved site, such as the Ctrl-C tests in `ScriptReplTests`
  and `ControllerRunTests`, still deliver it and still see the helper's exit
- The REPL session still gets its input pipe, and still reads its output as it arrives
- The As built block says that M3 pins the fix and not the bug, since no test can force a process id's reuse
- `spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md` is closed as fixed

### M4: The product's kills signal by audit token

**Status:** NOT STARTED

Needs nothing from M1 to M3. It lands before M3, since M3's sender wraps its calls.

- `ProcessInspection` reads a process's audit token, signals by a token, and reads a start time to the microsecond, as
  public calls. The token read releases its task name port on every path
- `AuditToken` moves from `FileRouting` into `ProcessInspection`, and `FileRouting` depends on `ProcessInspection`.
  One `AuditToken` type exists in the package. Its fields and `init?(data:)` are unchanged
- `Package.swift` lists `BrowserApplet`'s new `ProcessInspection` dependency, and the comment on `ProcessInspection`
  names every target that uses it
- `ProcessInspectionTests` signals a live child by a token whose pid version is one off, and the child stays alive.
  The matching token ends it. A token for a reaped child returns ESRCH. The call's errno-style return is read as such
- `WebContentProcess`'s `Signal` seam receives the identity the product read, its token included. Fakes with a made-up
  pid carry no token
- `WebContentProcess.kill` keeps its path check on both paths. With a token, it then signals by the token. With none,
  it signals as today
- A product test injects `pathOf` to name a content process, with the live token signal. `kill` on a live child whose
  token is one pid version off returns false, and the child stays alive. The matching token ends it. A token for a
  reaped child returns false
- A BrowserApplet test fails when a real view's content process gives no token. The product logs a failed token read
- The closed-process watch stores the identity read at the close, and the fire signals that token. Nothing reads a
  token from a stored pid
- `killUnused` compares live views by pid, and no task name port is left open after a close
- `ProcessReaper` takes the helper's `AuditToken?` beside its `ProcessIdentity`, and signals by the token. With no
  token, it keeps its identity check. `ProcessIdentity`'s fields, equality, hashing, and `folderName` are unchanged
- The reaper's token is the connection's `peer.token`. A ScriptHost test attaches a helper, and sees the channel's
  recorded token equal the peer's
- A ScriptHost test spawns a child, and calls the reaper with a token one pid version off. The child stays alive
- Production's `busyShare`, bound, and time sources are unchanged
- The As built block records whether WebContent and the REPL helper gave a token, and says M4 pins the fix and not
  the bug, since no test can force a process id's reuse

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
- 2026-11-22: Scheduled as UTERM-046 M1-M2 in queue.md.
- 2026-11-23: Added M3, which moves every `ScriptHostTests` site that signals its helper by process id onto the
  fixture's handle. This came from bug triage of `spec/bugs/20261122-declared-file-watchdog-may-signal-reused-pid.md`.
  The audit decision read "Decision: logged flakes only. New flakes go through `spec/flaky-tests.md`'s Rule as they
  appear." It now also covers the neighbors that signal. The fixture decision's "Leaves undone" listed
  `DeclaredFileRunTests.start`, `ReplSupport`, the `isRunning` polls in `ControllerRunTests`, and `ScriptReplTests`' own
  helper run. M3 now moves those. Why: a raw signal after a reap can kill an unrelated process, and that is a correctness
  risk, not a flake. The user chose this over adding only `DeclaredFileRunTests.start` to M2. (addition)
- 2026-11-23: A design-critic pass on M3 found it sound with caveats. Moving every signal onto the fixture's handle is
  the only option that closes the race. Corrections of fact: M3 named four sites, but its catch-all check forbade about
  twenty more raw signals in `ScriptHostTests`. M3 now lists every site. Leaves undone said the `ScriptGrantTests`
  source session never signals. Its teardown terminates it, so it moved to M3. The Summary and the audit rationale still
  described only the two flakes. Routed checks to M2 that M3's sites need: caller-owned streams, a pty, a non-blocking
  exit query, any signal number, signals to the process and not its group, and `start` owning its own hang guard.
  Moved the SIGINT check for M2's callers into M2. Added the risk that a group-wide signal weakens the controller signal
  tests. M3 now starts after M2, and exempts signal 0 probes and the relay's forked child.
- 2026-11-23: The user chose to specify the fixture's wider spawn in M2, over extending it in M3. M2 owns the fixture,
  and building it once keeps it from changing shape after M2 lands. This serves M3's addition. (addition)
- 2026-11-23: The user chose to add `PresentationTests`' watchdog to M3, over filing it as a bug. The fixture moves to
  a test-support target that `ScriptHostTests` and `WindowKitTests` both import. (addition)
- 2026-11-23: The user chose to have moved sites expose only the fixture's handle, so `.terminate()` on them does not
  compile, over a source search alone. The search still covers bare `kill` on a process id.
- 2026-11-23: Scheduled UTERM-046 M3 in queue.md, in the same row as M1-M2.
- 2026-11-23: A re-check pass on M2 and M3 did not converge. Corrections of fact: the audit decision said the
  signalling tests covered `ScriptHostTests` and `PresentationTests`, and M3's checks covered "both targets". All of
  `WindowKitTests` held more sites, and so did five other test targets. `ControllerConsentTests`' kill sites had no
  handle in reach, since `run` returns only after `finish`. `ScriptReplLimitsTests`' reaper closure runs off the main
  actor. M3's search would have hit the handle's own sender and `ReplProcess.interrupt`. M3 named an unnamed "second
  session". The fixture's target is `ScriptTestSupport`, which both test targets already import. Routed checks to M2:
  the handle's sender is `signal(_:)`, and a stopped helper still reads as running. Routed the handle hand-off, the
  reaper lookup, and the rename to M3.
- 2026-11-23: The user chose to close the race in every package test, over narrowing M3 to `ScriptHostTests` and
  `PresentationTests` and filing a bug for the rest. "Filing a bug while designing the proposal that would've fixed
  the bug is idiotic." The audit decision said "every test that signals a process it spawned by process id. That
  covers `ScriptHostTests` and the watchdog in `WindowKitTests`' `PresentationTests`." It now covers every package
  test that signals a process by its id. M3 adds `SenderWatcherTests`. The sites whose process the product,
  libghostty, or WebKit reaps open "How a test signals a process it does not reap". Status set to designing until it
  settles. (addition)
- 2026-11-23: A design-critic pass on "How a test signals a process it does not reap" added the audit-token sender.
  Corrections of fact: the question said "macOS has no process handle that a non-parent can hold, so no option closes
  the window". `proc_signal_with_audittoken` signals only the process a token names. The identity check said
  "start time, to the microsecond, from `proc_pidinfo`". `proc_pidinfo` refuses `login`, so it reads sysctl. The
  question said libghostty "spawns and reaps that shell". It spawns and reaps `login`, and the shell is reparented. The
  terminal teardowns kill `login`'s freed pid on every run, which the question did not say. Added the checks each site
  makes when it learns a pid, and the orphan `RemoteClientWatcherTests` leaves.
- 2026-11-23: The user chose the audit-token sender, with the identity check as its fallback where no token can be
  read. The user preferred it over the identity check alone, an exit watch, stopping the signals, and signalling
  through each owner. Routed its checks to M3, and added the risk that the call changes or goes away.
- 2026-11-23: The user chose to fix the product's `WebContentProcess.kill` here, over keeping production out. Amended
  "Production behavior does not change". It said "production code keeps its bounds, its time sources, and its
  `busyShare`", with no production change at all. The kill now signals by the content process's token, and keeps its
  path check when it reads none. The bounds, time sources, and `busyShare` stay as they were. (addition)
- 2026-11-23: The user chose to have `RemoteClientWatcherTests` end the client its `sh` forks, through the sender, over
  leaving the orphan. (addition)
- 2026-11-23: A final re-check pass did not converge. Corrections of fact: the decision put "one sender in
  `ScriptTestSupport`" behind every site. Five site targets do not import it, and the product cannot import a test
  target. The product's token path dropped `WebContentProcess.kill`'s rule that it "refuses what is not a content
  process". The product change sat in M3, a test milestone gated on M2. The rationale said the orphan "is a
  reparented process, which only this sender can end safely". At `tearDown` it is still `sh`'s child. The re-check
  also found ScriptHost's `ProcessReaper` sends `Darwin.kill` after a one-second identity check. Moved the product
  change into M4, which M3 now follows. Renamed "Production behavior does not change" to "Production keeps its rules",
  since its body allows a change. Added the risk that WebContent refuses a token. Routed the ESRCH, seam, port, and
  tree-parent checks.
- 2026-11-23: The user chose `ProcessInspection` for the token read, the token signal, and the microsecond start time.
  A new `ProcessTestSupport` target holds the per-site sender. The user preferred that over putting the sender in the
  product library too, and over keeping it in `ScriptTestSupport`. Amended "How a test signals a process it does not
  reap": it said "an audit-token sender in `ScriptTestSupport`". (addition)
- 2026-11-23: The user chose a process group and `killpg` for the `RemoteClientWatcherTests` client, over the token
  sender. The earlier recommendation of the sender rested on the false claim that the client was reparented. Amended
  the same decision: it said the test "ends the client its `sh` forks through the sender".
- 2026-11-23: The user chose to move ScriptHost's `ProcessReaper` onto the token signal in M4, over keeping it out.
  Amended "Production keeps its rules" to name it beside `WebContentProcess.kill`. (addition)
- 2026-11-23: Added M4 for the product's two kills. M3 follows it.
- 2026-11-23: A re-check of M4 found every change sound, with one design gap: the token's type. Corrections of fact:
  M4 said `ProcessReaper` "records a token with each `ProcessIdentity`". A stored token breaks that type's equality and
  its `folderName` round trip, so the token now rides beside it. The decision said `ProcessReaper` reads its own token.
  The REPL channel already holds the token the kernel gave its connection, so it records that one. M4 had
  `killUnused` read a token for every live view. Comparing pids gives the same outcome. "Five more test targets"
  is four, since `RemoteClientWatcherTests` no longer needs the sender. Routed checks to M4: the watch fires the token
  read at the close, `BrowserApplet`'s new dependency is listed, and M4 pins the fix and not the bug.
- 2026-11-23: The user chose to move the existing `AuditToken` from `FileRouting` into `ProcessInspection`, with
  `FileRouting` depending on `ProcessInspection`. The user preferred it over a second token type and over a raw
  `audit_token_t`. Amended "How a test signals a process it does not reap" to name the type. (addition)

## References

- ADR-07: Failure isolation
- ADR-08: UI responsiveness
- `spec/flaky-tests.md`
- UTERM-045, whose closing rule in the `spec/flaky-tests.md` Rule section decides when this proposal's entries move to
  Fixed
