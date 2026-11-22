# Calls held during a peer's full check grow without bound

**Status:** open
**Validation:** not confirmed; traced in code only, not reproduced. The window lasts only as long as the signature
check, so a repro needs a peer that sends calls quickly during it.

## Observed

A program that begins a session and is not taken at once for the bundled command waits for a full check of its
signature. Every call it sends meanwhile is kept, with no limit on how many. A program that floods calls in that window
makes the app hold all of them in memory.

## Cause

`begin` (`Packages/UnitermKit/Sources/ScriptHost/ScriptUndeclared.swift`, about lines 114-128) sets
`heldRequests[connection.id] = []` and runs the check off the main actor. While it runs, each `.request` event appends
to that list (`Packages/UnitermKit/Sources/ScriptHost/ScriptHost.swift`, about lines 454-457) with no count. `begun`
then replays every held call (`ScriptUndeclared.swift`, about lines 133-142).

## Repro

1. Start a program that begins a session and fails the cheap check, so it gets the full check.
2. Have it send many calls before the check returns.

Expected: past a bound, further calls are answered `busy`. Actual, per the trace: every call is kept and replayed.

## Fix

Bound the held list per connection. Past the bound, answer each further call `busy`, as the host already does when a
program's waiting requests are full. UTERM-043's pause, if it holds calls at admission, needs the same kind of bound.
