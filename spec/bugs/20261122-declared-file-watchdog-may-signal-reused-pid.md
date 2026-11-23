# The declared-file test watchdog may signal a process id that was already reused

**Status:** open
**Validation:** not confirmed; traced by reading the code, no reuse was observed
**Found:** 2026-11-22, during the UTERM-046 review
**Estimate:** large; two non-trivial decisions (see Estimate notes)

## Observed

`DeclaredFileRunTests`' 60 s watchdog checks `isRunning`, then sends SIGKILL to `processIdentifier`. If the helper
exited and Foundation reaped it, the id is free for reuse. Should `isRunning` still read true at that moment, the
watchdog kills an unrelated process of the same user.

## Cause

`Packages/UnitermKit/Tests/ScriptHostTests/DeclaredFileRunTests.swift:136-138`. The check and the signal are two steps,
and the test does not own the reap. UTERM-046 logs a sighting where `waitUntilExit` hung after the helper exited. That
suggests `Process`'s view of the exit can lag or miss.

## Fix

Move this helper onto the fixture's own spawn-and-reap handle that UTERM-046 M2 builds. The fixture signals only before
its own `waitpid` reap, so the id cannot be reused. M2 moves every `finish` path. It does not name this watchdog in
`start`, so check it off there.

## Estimate notes

Checked 2026-11-23 by reading the code. Not reproduced. A reused process id cannot be forced in a test, so the
race stays traced, not observed. Both watchdogs sit at `DeclaredFileRunTests.swift` lines 136-138 (`start`) and
160-164 (`run`).

The fix as written does not exist yet. UTERM-046 M2 is NOT STARTED. The proposal's "Leaves undone" list names
`DeclaredFileRunTests.start` as staying on Foundation's `isRunning`. M2's caller list names `DeclaredFileRunTests.run`
but not `start`. So the bug's "check it off there" step means widening M2's scope. That is a scope addition.

The same `isRunning` then `kill(processIdentifier)` pair also appears in `ReplSupport.swift`, `ScriptLintCommandTests`,
`ScriptAskRunTests`, `ControllerRunTests`, `ControllerConsentTests`, `ScriptRunCommandTests`, `ScriptLimitsTests`, and
`ScriptReplTests`. The bug names only one site.

Non-trivial decisions:

1. Whether `start` joins M2's scope, or the proposal keeps it out and this bug waits. A smaller stopgap exists, such
   as dropping the SIGKILL watchdog from `start`. That option loses the hang guard.
2. Whether the other sites with the same pair are fixed by this bug, by M2's neighbors step, or stay open. The
   proposal currently leaves them undone on purpose.

Files a fix would touch: `DeclaredFileRunTests.swift`, `Support.swift` (the fixture), and the UTERM-046 proposal text.
