# UTERM-045: Settle Input Before UI Tests Send It

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

UI tests send synthesized wheels, clicks, and keys. When an event arrives before its target can take it, the test fails
with no change to the code. This proposal gives the UI test base class one way to aim and send a wheel that settles the
pointer first, once CI shows the launcher change holds. Which call sites move onto it is open. It also states when a
flaky entry may close.

## Motivation

One logged flake has evidence of a pointer race. In a CI failure of the launcher scroll test on #90, the first wheel
scrolled the middle pane's launcher while the same lookup gave the focused list's frame just before and after it. The
change "Settle the pointer on the launcher list before the scroll test's wheels" moves the pointer onto the list and
waits until it is inside before any wheel. That change is a hypothesis. A local run that left the pointer over the
middle pane still passed, and CI had run it once by the time this proposal was filed.

The other wheel sites, such as the image viewer's scroll test (`UITests/ImageViewerUITests.swift:507-538`), send raw
`element.scroll` calls with no settle. If the race is real, they share it.

Most other entries in `spec/flaky-tests.md` point elsewhere. The open-panel failures involve a panel in another
process. Several entries record a single synthesized event taking 5 to 20 s. `TerminalLinkUITests` failed because a
person moved the real mouse during a local run. The PaneTree entry's own check rules out a responder race in the app.

## Design Decisions (Settled)

### Test code only

Decision: the change lives in the UI test target. No product code changes.

Rationale: the events are synthesized by the test, and the race is between the test and the window server.

### No retries and no longer timeouts

Decision: a settle waits for a stated precondition, such as the pointer inside the target's frame, and fails with a
report when it never holds. It never resends an event or widens a timeout. It never waits for the app's response to an
event.

Rationale: the flaky-test rule forbids fixing a flake with retries, longer timeouts, or weaker assertions. A wait for
the test's own precondition removes the race, and its failure names which precondition did not hold.

### When an entry closes

Decision: an entry moves to Fixed only with a fix commit, and only after enough clean CI `app` runs that a flake still
present at its observed rate would very likely have shown. For an entry seen once in N runs, that is about 3N clean
runs, which gives a 95% chance of seeing it again. An entry seen too rarely to reach that stays under Potential, with
the change named. A run that fails with a settle's report closes nothing. It records a new cause on the same entry.

Rationale: the launcher entry moved to Fixed after one change on 2026-11-21, and CI then failed it again. Three clean
runs say little about a flake seen once in twenty.

## Design Decisions (Open)

### Which call sites move

- **Every synthesized wheel.** Every wheel goes through one base-class entry point that aims and settles, so a new
  wheel test gets the settle by default. Takes in the image viewer's wheels, which have no flaky entry. An addition.
  Leaves undone: keys, and the `QuestionsUITests` Escape retry.
- **Wheels and keys.** As above, plus a keyboard-focus settle before keys. Today a test waits once for the app to be
  frontmost, in `waitForTerminal` (`UnitermUITestCase.swift:127`), not before each key. A focus settle would wait for
  the app's first responder, which is the app's response
  to the last action, against the decision above. It also cannot see the open panel, which runs in another process.
  `QuestionsUITests` resends Escape up to three times for a panel not yet ready, a retry this option would have to
  replace. An addition.
- **Flaky entries only.** Only tests with a logged pointer flake move, which today is the launcher test. Leaves undone:
  raw wheels elsewhere, and the `QuestionsUITests` Escape retry.

### How the wheel is aimed

- **Hover, wait, then the element's scroll.** What the launcher change does. Whether XCUI's element scroll moves the
  pointer again before the wheel is not known.
- **Scroll at a coordinate.** `XCUICoordinate.scroll(byDeltaX:deltaY:)` sends the wheel at an explicit point, which also
  avoids XCUI's hit-point lookup that fails for the launcher's scroll view. Whether it removes the race is not known.

The xcresult activity log for one wheel shows which events XCUI synthesizes, and decides between these.

### Whether clicks need settling

XCUI's `click()` aims at the element as part of the click. Whether a click can land before the pointer arrives is not
known, and no logged flake shows it. Candidates: settle clicks too, or leave clicks until a flake shows the race.

### Whether to detect outside input

- **No detection.** Document that a local UI run needs the pointer and keyboard left alone.
- **Check pointer drift.** Before each event, compare the pointer with where the settle put it, and fail when a person
  moved it. An addition. Leaves undone: a person's modifier keys still change synthesized input, which was the
  TerminalLink cause.

## Risks

- **The launcher hypothesis is wrong** — likelihood: medium, impact: medium.
  Mitigation: M2 starts only after M1's clean count. A CI failure with the pointer inside the list disproves the cause,
  and the proposal is then retargeted or retracted, before anything is built on it.
- **A settle never actually waits** — likelihood: medium, impact: low.
  Mitigation: if `hover()` returns only after the pointer moved, the wait proves the precondition but guards nothing.
  The aiming question above decides what the settle actually guards, and its comment says so.
- **The settle reads the wrong coordinate space** — likelihood: low, impact: low.
  Mitigation: a wrong conversion fails the wait every time, never silently. The launcher change's local runs already
  passed with it.

## Milestones

### M1: The launcher change holds in CI

**Status:** NOT STARTED

- The `spec/flaky-tests.md` Rule section states the closing rule above, in place of moving an entry to Fixed on a fix
  commit alone
- The launcher change has run clean in CI `app` runs to the count the closing rule sets. A clean run is one in which
  the launcher test did not fail. M2 does not start before that count
- A CI failure with the pointer inside the list sends the proposal to the user to retarget or retract
- A CI failure in which the settle's own wait timed out, or the pointer left the list after the settle, is recorded in
  the launcher entry and reopens the aiming question

### M2: One way to send a wheel

**Status:** NOT STARTED

- The base class aims and settles a wheel in one call, and reports the pointer and the target's frame when the
  precondition never holds
- The settle reads the target's frame on each poll
- Every call site the scope question names uses it, and no raw wheel remains among them
- A settle that times out fails with its own message, distinct from the test's own assertion
- CI `app` runs, not local runs, prove the change, to the closing rule's count

## Decision Log

- 2026-11-21: Filed during a landing run in which UI flakes cost several CI reruns. The user asked whether this
  flakiness could be fixed for the future.
- 2026-11-21: A design review found the premise rested on one unconfirmed pointer race. The user chose to gate the work
  on CI evidence for the launcher change, widen the scope candidates to every synthesized wheel, and state a closing
  rule.

## References

- `spec/flaky-tests.md`
- UTERM-044, which shortens each rerun a flake costs
