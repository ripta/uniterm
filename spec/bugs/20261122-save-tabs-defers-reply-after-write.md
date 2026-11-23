# UTERM-049's `save-tabs` reply waits for a file write, against ADR-11

**Status:** open
**Found:** 2026-11-22, during the UTERM-054 review
**Validation:** confirmed by reading the specs; the command is not built, since UTERM-049 M3 is NOT STARTED

## Observed

UTERM-049 settles that a program's `save-tabs` shows the user's Save Tabs As panel, and that "the reply is the path
written, or a cancel". M3 checks that "the reply names the path written, or says the user cancelled". So the reply
waits for the user's pick and for the atomic write.

ADR-11 says an applet reply may be deferred only for a command with no effect, and a command with an effect replies at
once. Writing a file is an effect. A revocation, run end, or pane close while the reply is pending fails it after the
file may already be written. The program then reads a failure for a save that stands, and may save again.

## Cause

`spec/proposals/UTERM-049-save-and-open-browser-tab-sets.md`, "A program saves tabs through the user's save panel"
(around line 279) and M3's reply check (around line 510). Neither names ADR-11 or a handle.

## Repro

Read the two passages beside ADR-11's "Decision". A program calls `save-tabs`, the user picks a path, and the program's
run is revoked during the write. Expected under ADR-11: the program learns the save stands. Under UTERM-049 as written,
the pending reply fails.

## Fix

UTERM-049 is accepted, so the fix amends it in place. It needs one design call:

- Reply at once with a handle. The panel's outcome and the path arrive under that handle, with a completion event, as
  ADR-11 prescribes for a slow command with an effect.
- Settle the reply when the user confirms the panel, before the write starts. The reply carries the chosen path. A write
  failure goes to the user's alert, as the user's own save does, and the program never learns of it.
- Treat the panel itself as a read until the user confirms, and state in UTERM-049 why a revocation during the write
  cannot happen, if the write is guaranteed to finish first.
