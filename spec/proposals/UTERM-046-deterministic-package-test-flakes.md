# UTERM-046: Make the Logged Package-Test Flakes Deterministic

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

Two package-test flakes fail CI on a loaded runner with no change to the code. The browser's hung-process tests give a
spinning page 0.3 s of real time and expect it to use half a core. The script fixtures miss a helper's exit and hang.
This proposal makes both deterministic, without weakening what the tests prove.

## Motivation

The browser test `BrowserHungProcessTests.testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` failed on #91's CI.
Its assertion at line 294 found no signal sent: `[] is not equal to [12101]`. The test already runs the bound by hand
through `ManualHangTimer`. What it does not control is the sample. Before firing, it waits 0.3 s of real time in
`letTimePass` (`BrowserHungProcessTests.swift:183`). `ClosedProcessWatch` then signals only when the page used at least
`busyShare`, half a core, over that window (`Sources/BrowserApplet/WebContentProcess.swift:149,169`). On a loaded
runner a spinning page can get less than half a core. The watch then rightly sends nothing, and the test fails. Six more
places in the same class use `letTimePass` (lines 289 to 510), and one test asserts each side of `busyShare` against
live samples (lines 330 and 331).

`ScriptFixtures.finish` (`Tests/ScriptHostTests/Support.swift:214`) has hung twice, logged in `spec/flaky-tests.md`.
Each time it blocked in `waitUntilExit` after its helper had exited, and the 120 s hang guard aborted the run. Its
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

## Design Decisions (Open)

### How the closed-tab tests get their sample

- **Supply a busy sample end to end.** The closed-tab tests pass a sample through `policy.process.sample` that reads as
  busy. They keep the real signal and the real process exit. `ClosedProcessWatch`'s decision is already pinned by its
  own tests with supplied samples. Leaves undone: the live-sample test, which reads real CPU use by design.
- **Make the live window load-independent.** `letTimePass` stops spinning on the main thread, and the test fires only
  once its own sample reads busy. Every test keeps live samples. Leaves undone: a runner loaded by other processes can
  still starve the page.
- **Both.** Closed-tab tests supply their sample, and the one live-sample test waits until it reads busy.

### How the test waits for the process to end

`waitUntilGone` polls for up to 15 s. The WebContent process is not the test's child, so `waitpid` cannot see it.

- **Keep the poll.** It already waits for an event, with a deadline.
- **Wait on the exit event.** `DispatchSource.makeProcessSource` with an `.exit` event mask reports the end of any
  process the test can see.

### How the fixture waits for its helper

- **A termination handler.** Set `terminationHandler` before `run()`, and resume when it fires, after reading both pipes.
- **`waitpid` on the child.** The helper is the test's child, so `waitpid` sees its exit directly.

Both replace `waitUntilExit`. The watchdog's `isRunning` gate needs the same review, since it can signal a process id
that another process now holds.

### How far the audit goes

- **Logged flakes only.** The two above, and each new entry as it appears.
- **Every real-time wait in the package tests.** Classify each as a wait for an event, a deadline guard, or a real
  sleep, and fix every sleep that stands in for an event. The calls cluster in the terminal session integration tests,
  the exec pane tests, the exec driver channel tests, and the Markdown viewer tests. This is an addition, and it needs
  its own milestone.

## Risks

- **A supplied sample hides a broken live reading** — likelihood: low, impact: medium.
  Mitigation: the live-sample test keeps reading real CPU use, so a broken reader still fails a test.
- **A new wait mechanism misses an exit the old one saw** — likelihood: low, impact: low.
  Mitigation: the fixture's change is proven against a helper that exits at once and one that exits after a delay.

## Milestones

### M1: The browser hung-process tests

**Status:** NOT STARTED

- `BrowserHungProcessTests` passes on a runner whose cores are all busy with other work
- The live-sample test still fails when the reader reports a spinning page as idle
- `spec/flaky-tests.md` lists the closed-tab test under Potential, with this change, until CI runs show it holds
- Production's `busyShare`, bound, and time sources are unchanged

### M2: The script fixture's helper exit

**Status:** NOT STARTED

- `ScriptFixtures.finish` returns once its helper exits, without `waitUntilExit`
- The watchdog never signals a process that has already exited
- The `ScriptFixtures.finish` entries in `spec/flaky-tests.md` record the change and stay under Potential until CI runs
  show it holds

## Decision Log

- 2026-11-21: Filed during a landing run in which two package-test failures cost CI reruns. The user asked whether
  this flakiness could be fixed for the future.
- 2026-11-21: Re-scoped from "inject clocks into timing-sensitive package tests". A design review found neither
  motivating test was a clock problem. The exec stall test was already fixed, and the browser test already injects its
  bound. The user chose to re-scope around the actual flake mechanisms.

## References

- ADR-07: Failure isolation
- ADR-08: UI responsiveness
- `spec/flaky-tests.md`
