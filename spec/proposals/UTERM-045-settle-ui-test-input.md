# UTERM-045: Settle Input Before UI Tests Send It

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Impacts

- UTERM-044 — Risks: "Splitting moves a flake rather than fixing it" names this proposal as part of the fix.

## Summary

UI tests send synthesized keys, clicks, and scroll wheels. Several logged flakes fail because an event arrived before
its target could take it. This proposal adds shared helpers to the UI test base class that settle the pointer and the
keyboard on their target first. It then moves the flaky tests onto them, one at a time, each on its own evidence.

## Motivation

`spec/flaky-tests.md` lists 24 open entries. Many share one shape: the test sent an event, and the app never saw it.

- The launcher scroll test's first wheel scrolled the middle pane's list on CI. The pointer had not yet reached the
  focused list. "Settle the pointer on the launcher list before the scroll test's wheels" fixed that one test in place.
- The PaneTree, Windows, and open-panel entries record keys that went nowhere.
- `TerminalLinkUITests` failed when a real mouse moved during a local run. Real events carry the real modifiers, so the
  synthesized Command was lost.

The base class already waits for the app to be frontmost before the first key, in `waitForForeground`
(`UITests/UnitermUITestCase.swift:233`). It has no equivalent for the pointer. Each test that needs one writes its own,
as the launcher test now does.

## Design Decisions (Settled)

### Test code only

Decision: the helpers live in the UI test target. No product code changes.

Rationale: the events are synthesized by the test. The app handles real input correctly. The race is between the test
and the window server.

### No retries and no longer timeouts

Decision: a helper waits for a stated condition, such as the pointer inside the target's frame, and fails with a report
when it never holds. It never resends an event or widens a timeout.

Rationale: the flaky-test rule forbids fixing a flake with retries, longer timeouts, or weaker assertions. A wait for a
named condition is not one of those. It removes the race, and its failure says which condition did not hold.

### Each entry closes on its own evidence

Decision: moving a test onto a helper does not close its flaky entry. The entry closes after CI runs show the failure
gone, or after a run fails with the helper's report and names a different cause.

Rationale: on 2026-11-21 the launcher entry moved to Fixed after one change, and CI then failed it again. A change that
fits the evidence is a hypothesis until runs confirm it.

## Design Decisions (Open)

### Which entries are in scope

- **Pointer events only.** Wheels and clicks, where the launcher evidence points. The lost-key entries stay as they are.
- **Pointer events and keys.** Keys already wait for the app to be frontmost. A lost key after that may be a different
  race, such as the first responder moving after a close. This option adds a keyboard-focus settle, and needs evidence
  per entry that focus, not the app, was the problem.

### Whether clicks need settling

XCUI's `click()` moves the pointer as part of the click, unlike a wheel sent with `scroll(byDeltaX:deltaY:)`. Whether a
click can land before the move is not known. Candidates: settle clicks too, or settle only wheels and hovers until a
click flake shows the same race.

### Whether to detect outside input

A real mouse or keyboard moving during a local run breaks synthesized input. Candidates:

- **No detection.** Document that a local UI run needs the pointer and keyboard left alone.
- **Detect and name it.** A helper notices a pointer move the test did not make, and the failure says so. This needs a
  way to tell the test's events from a person's, which is not known to exist.

## Risks

- **A settle helper hides a real product bug** — likelihood: low, impact: medium.
  Mitigation: a helper only waits for the test's own precondition, such as where the pointer is. It never waits for the
  app's response, so a product that drops a well-aimed event still fails.
- **The helper's condition reads the wrong coordinate space** — likelihood: low, impact: low.
  Mitigation: the launcher fix converts AppKit's bottom-left pointer to XCUI's top-left frames, and its run proves the
  conversion. The shared helper keeps that conversion and its proof.

## Milestones

### M1: Shared pointer settle

**Status:** NOT STARTED

- The base class settles the pointer inside a target's frame before a wheel, and reports the pointer's position when
  it never arrives
- The launcher scroll test uses the shared helper in place of its own
- The `LauncherUITests` class passes locally with the shared helper

### M2: Move the flaky tests onto the helpers

**Status:** NOT STARTED

- Each in-scope flaky entry names the helper its test now uses, or why it does not apply
- No entry moves to Fixed without CI runs that show the failure gone

## Decision Log

- 2026-11-21: Filed during a landing run in which UI flakes cost several CI reruns. The user asked whether this
  flakiness could be fixed for the future.

## References

- `spec/flaky-tests.md`
- UTERM-044, which shortens each rerun a flake costs
