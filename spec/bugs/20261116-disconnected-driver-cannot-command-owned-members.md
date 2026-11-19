# A driver whose pane is disconnected cannot command the members it owns

**Status:** fixed 2026-11-18
**Fixed:** 2026-11-18
**Estimate:** small; no open design decisions. UTERM-028 "Members while the anchor is disconnected" settled the
authority call, and the fix did not wait for that milestone. A driver whose pane is disconnected and that owns no group
keeps the enable-remote-control refusal, as `requireSomeAuthority` does for scripts.
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
UTERM-004 "Layout requests" keeps the remote-controlled anchor for layouts. The fix was first held for UTERM-028 M1,
whose check "A version-4 driver with a disconnected anchor commands its remote-controlled members" covers it. On
2026-11-18 the user chose to land it ahead of that milestone.

## Fix note

`MainWindowController+Exec.swift` now splits the old `beyond` check. The driver, owner, and revoke refusals apply to
every request. The disconnected-pane refusal applies to layouts, and to commands only while the run owns no group. A
disconnected driver keeps commanding the remote-controlled members it owns. A disconnected driver with no group, and a
disconnected anchor's layout, still get the enable-remote-control refusal, now worded for the request kind. A revoke
still ends member commands.

Regression test: `ExecLayoutTests.testADisconnectedDriverStillCommandsTheMembersItOwns`, which failed on the unfixed
code with the disconnect refusal. `testADisconnectedDriverWithNoGroupIsToldToEnableRemoteControl` and
`testAMalformedLayoutFromADisconnectedPaneIsRefusedForTheDisconnect` pin the refusals that stay.
