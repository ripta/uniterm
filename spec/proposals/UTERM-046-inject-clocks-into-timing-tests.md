# UTERM-046: Inject Clocks Into Timing-Sensitive Package Tests

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

Some package tests measure real time. A loaded CI runner then fails them with no change to the code. This proposal moves
those tests to injected clocks, where the code under test lets them, and settles what to do where it does not.

## Motivation

The coding standards say "Inject clocks. Do not add real timers, real sleeps, or long polls." Several package tests
still use real time, and CI failures trace to them:

- `ExecDriverChannelTests.testAStalledStdinFailsWithoutBlockingTheEmitter` failed on PR #81's CI when 40,000 emits took
  5.15 s against its 5 s wall-clock bound.
- `BrowserHungProcessTests.testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut` failed on #91's CI, timed out
  waiting for a closed tab's process to end. Other tests in the same class already feed the watch supplied samples. This
  one runs a real WebContent process through the real bound.
- `ScriptFixtures.finish` has hung three times, blocked in `waitUntilExit` after its helper had exited. That is a missed
  process exit, not a time bound. The hang guard only shows it after 120 s.

Real-time calls appear across the package tests, most in the terminal session integration tests, exec pane tests, the
exec driver channel tests, and the Markdown viewer tests. `StatusCenter` already takes an injected clock through its
own `StatusClock` protocol, so the pattern exists in the codebase.

## Design Decisions (Settled)

### Production timing does not change

Decision: production code keeps its bounds and its default time source. A clock injected for a test replaces only how
time is measured, never the bound or what happens when it runs out.

Rationale: the browser's hung-process bound and the exec driver's stall handling are how a hung part stays contained,
per ADR-07. A test shortcut that weakened them would trade a flaky test for a weaker product.

### No new waits on the main thread

Decision: making a test deterministic never adds a wait to the main thread.

Rationale: ADR-08 says the main thread never waits on work whose duration uniterm does not bound.

## Design Decisions (Open)

### Which clock

- **Swift's `Clock` protocol.** Production uses `ContinuousClock`. Tests supply a clock they advance by hand. Standard
  across Swift code.
- **A project protocol per need.** Narrower, and shaped to what the code needs, such as "now" and "sleep until".
  `StatusCenter`'s `StatusClock` already works this way. Each one is another abstraction to keep.

### How far the audit goes

- **Logged flakes only.** Fix the tests above, and any new entry as it appears.
- **Every real-time call in the package tests.** Classify each one as a bound under test, a wait for an event, or a
  real sleep, and fix every bound and sleep. Larger, and it finds the next flake before CI does.

### What to do with a test of a real process

The browser test above proves that a real process ends when its bound runs out. An injected clock can run the bound
out, but the process still ends on the system's schedule. Candidates:

- Keep it as an end-to-end test with its real wait, and log it, since no cheaper layer proves the same contract.
- Inject the clock for the bound, and wait for the process exit as an event rather than by polling.

### Whether the script fixture hang belongs here

- **Fold it in.** It is a test that waits on real time, through `waitUntilExit`.
- **File it as a bug.** Its cause is a missed process exit, which a clock does not fix.

## Risks

- **An injectable clock is left reachable in production** — likelihood: low, impact: medium.
  Mitigation: the clock is an initializer parameter with the production clock as its default. No setting or
  environment variable selects it.
- **A test advances its clock past a race that real time would hit** — likelihood: medium, impact: low.
  Mitigation: each converted test keeps one check against the real bound's value, so the bound itself stays proven.

## Milestones

### M1: Fix the logged timing flakes

**Status:** NOT STARTED

- The exec driver stall test and the browser hung-process test no longer depend on the runner's speed
- Each test's flaky entry, if it has one, records the change and stays under Potential until CI runs show it holds
- Production bounds and defaults are unchanged, and a test proves each bound's value

## Decision Log

- 2026-11-21: Filed during a landing run in which two package-test timing failures cost CI reruns. The user asked
  whether this flakiness could be fixed for the future.

## References

- ADR-07: Failure isolation
- ADR-08: UI responsiveness
- `spec/flaky-tests.md`
