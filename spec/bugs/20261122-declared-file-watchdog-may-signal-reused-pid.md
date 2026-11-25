# The declared-file test watchdog may signal a process id that was already reused

**Status:** open
**Validation:** not confirmed; traced by reading the code, no reuse was observed
**Found:** 2026-11-22, during the UTERM-046 review

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
