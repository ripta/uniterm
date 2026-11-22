# Calls held during a peer's full check grow without bound

**Status:** not-reproducible
**Validation:** `UndeclaredFileTests.testAFloodDuringTheFullCheckHoldsNoMoreThanTheInFlightLimit` sends 24 calls while
a gated full check runs. The host held 8 and no more over a bounded wait of 500 ms, and answered all 24 once the check
passed. With the reader's `slots.wait()` removed, the same test failed with 24 held, so the test sees the bound. It does
not show the bound under every timing.

## Observed

A program that begins a session and is not taken at once for the bundled command waits for a full check of its
signature. Every call it sends meanwhile is kept, with no limit on how many. A program that floods calls in that window
makes the app hold all of them in memory.

## Cause

Refuted. See "Triage 2026-11-21" below. The text under this heading is the original report.

`begin` (`Packages/UnitermKit/Sources/ScriptHost/ScriptUndeclared.swift`, about lines 114-128) sets
`heldRequests[connection.id] = []` and runs the check off the main actor. While it runs, each `.request` event appends
to that list (`Packages/UnitermKit/Sources/ScriptHost/ScriptHost.swift`, about lines 454-457) with no count. `begun`
then replays every held call (`ScriptUndeclared.swift`, about lines 133-142).

## Repro

1. Start a program that begins a session and fails the cheap check, so it gets the full check.
2. Have it send many calls before the check returns.

Expected: past a bound, further calls are answered `busy`. Actual, per the trace: every call is kept and replayed.

## Fix

Refuted. See "Triage 2026-11-21" below. The in-flight limit already bounds the list, so no change is needed.
The text under this heading is the original suggestion.

Bound the held list per connection. Past the bound, answer each further call `busy`, as the host already does when a
program's waiting requests are full. UTERM-043's pause, if it holds calls at admission, needs the same kind of bound.

## Triage 2026-11-21

The cause is wrong. `ScriptConnection` stops reading at `maxInFlight` (8) calls with no answer, and a held call has no
answer until the check decides. So the held list holds at most 8 calls per connection. The in-flight limit is the bound
this file asks for.

`UndeclaredFileTests.testAFloodDuringTheFullCheckHoldsNoMoreThanTheInFlightLimit` pins it. It passes on the unchanged
code. A pause that holds calls at admission without leaving them unanswered would need its own bound.
