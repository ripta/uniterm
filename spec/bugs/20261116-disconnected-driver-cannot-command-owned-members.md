# A driver whose pane is disconnected cannot command the members it owns

**Status:** open
**Estimate:** small; no open design decisions. UTERM-028 "Members while the anchor is disconnected" settled the one
call. The fix is in `MainWindowController+Exec.swift`: split `beyond` so the ownership and revoke checks apply to every
request, and `sourceRefusal` applies to layouts only. The command authority at line 432 uses the first part alone. It
needs one regression test in `ExecLayoutTests.swift`, beside `testADriverInADisconnectedPaneCannotLayOut`. The suite
already has a driver fixture, so no new test applet is needed.
**Found:** 2026-11-16, by the design critic reviewing UTERM-028

## Observed

An exec driver lays out a group and commands its remote-controlled members. The user then disconnects the driver's own
pane. Every later command from the driver to those members is refused with "This driver's pane is disconnected". A
script whose source pane is disconnected keeps commanding the groups it owns.

The code follows UTERM-004's Decision Log entry of 2026-11-11, which made member commands need the driver's own pane
remote-controlled. UTERM-004 disagrees with itself, though. "How control is enabled" says disconnect and revoke are
separate, and that a disconnected source may still call targets it already owns. `disconnect`'s doc comment says the
pane's outbound calls to panes its controller owns are not affected. The driver path matches neither.

## Cause

- A member command checks `beyond()` first (`Packages/UnitermKit/Sources/WindowKit/MainWindowController+Exec.swift`
  around line 431). `beyond()` calls `sourceRefusal`, which refuses when the driver's own pane is not remote-controlled
  (lines 593-604).
- The script path instead lets a disconnected source keep its groups, in `requireSomeAuthority`
  (`WindowKit/WindowScripting.swift:519-531`).
- The `disconnect` doc comment is at `WindowKit/MainWindowController+Control.swift:94-96`.

## Repro

With a test applet that declares exec support, attach a driver to a remote-controlled pane. Have it lay out one
remote-controlled member, then disconnect the driver's pane and have it send a command to the member.

- Expected: the command runs, as a script's would.
- Suspected: it is refused, and the refusal tells the user to enable remote control.

## Fix

Accepted UTERM-028 "Members while the anchor is disconnected" settles the design call. Apply `sourceRefusal` to
layouts only, and let a member command rest on group ownership and the member's own mode, at every protocol version.
UTERM-004 "Layout requests" keeps the remote-controlled anchor for layouts. The change lands with UTERM-028 M1, whose
check "A version-4 driver with a disconnected anchor commands its remote-controlled members" covers it. Do not fix it
apart from that milestone.
