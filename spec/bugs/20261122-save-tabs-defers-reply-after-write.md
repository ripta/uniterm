# UTERM-049's `save-tabs` reply waits for a file write, against ADR-11

**Status:** fixed 2026-11-23
**Found:** 2026-11-22, during the UTERM-054 review
**Fixed:** 2026-11-23, by amending UTERM-049
**Estimate:** small; one non-trivial design decision, which the user settled: reply at once with a handle.

## Observed

UTERM-049 settles that a program's `save-tabs` shows the user's Save Tabs As panel, and that "the reply is the path
written, or a cancel". M3 checks that "the reply names the path written, or says the user cancelled". So the reply
waits for the user's pick and for the atomic write.

ADR-11 says an applet reply may be deferred only for a command with no effect, and a command with an effect replies at
once. Writing a file is an effect. A revocation, run end, or pane close while the reply is pending fails it after the
file may already be written. The program then reads a failure for a save that stands, and may save again.

## Cause

`spec/proposals/UTERM-049-save-and-open-browser-tab-sets.md`, "A program saves tabs through the user's save panel"
and M3's reply check. Neither named ADR-11 or a handle.

## Repro

Read the two passages beside ADR-11's "Decision". A program calls `save-tabs`, the user picks a path, and the program's
run is revoked during the write. Expected under ADR-11: the program learns the save stands. Under UTERM-049 as written,
the pending reply fails.

## Fix

UTERM-049 is accepted and M3 has no code, so the fix amended it in place. The triage on 2026-11-23 confirmed the text
was unchanged. Three approaches were weighed:

- Reply at once with a handle. The panel's outcome and the path arrive under that handle, as ADR-11 prescribes for a
  slow command with an effect.
- Settle the reply when the user confirms the panel, before the write starts. A write failure would reach only the
  user's alert, and the program would never learn of it.
- Treat the panel itself as a read until the user confirms. This needs a guarantee that no revocation lands during the
  write, and the spec gives none.

The user chose the handle, as the most correct and robust option. `save-tabs` now replies at once with a handle.
`wait-save` returns `saved` with the path, `cancelled`, or `failed` with the write error, and `discard-save` frees the
handle, following UTERM-022's `wait-form`. An interruption while the panel is up dismisses it and writes nothing. One
during the write lets the write finish, and the pending wait fails as ended without claiming the save was undone. M3's
checks cover each outcome, both interruptions, discard, and the handle cap.
