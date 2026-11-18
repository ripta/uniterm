# A disconnected pane that a live controller acts from shows no control badge

**Status:** open, reproduced at the mark level
**Estimate:** small, one file plus one test. One non-trivial decision: whether a disconnected pane with a live controller acting from it counts as the default state. The bug records that call as open.
**Found:** 2026-11-16, by the design critic reviewing UTERM-025

## Observed

A controller started from a terminal keeps acting after the user disconnects that terminal, through the groups it
already owns, per UTERM-004. The terminal is then disconnected, drives nothing, and is a member of no group. Its badge
does not show, so pane chrome offers no Revoke on it. UTERM-004 says pane chrome shows the mode, the owner, and the
driver, and exposes enable, disconnect, and revoke.

Not confirmed: no one has looked at such a pane in the running app, and hiding the badge may be intended.

## Cause

`PaneControlMark.isShown` (`Packages/UnitermKit/Sources/WindowKit/PaneFrameView.swift:42-45`) checks the access mode,
the driver, a group owner, an unowned group, and a saved intent. It does not read `controllers`, which its doc comment
says includes the controllers acting from the pane, or `revokeAvailable`.

## Repro

Enable remote control on a terminal pane. From it, run a controller whose layout opens a remote-controlled pane. Once
the layout lands, disconnect the terminal.

- Expected: the terminal's badge shows, and its menu offers Revoke Controller.
- Suspected: the terminal shows no badge. Revoke Controller still works from the palette with the terminal focused.

## Why it matters

UTERM-025's presenter tells the user to disconnect the starting terminal once the slide shows. If the user then closes
the slide pane, the only way left to end a background presenter is Revoke Controller from the palette.

## Fix

If it reproduces: show the badge when `controllers` is not empty. The design call is whether a disconnected pane with a
live controller acting from it counts as the default state.

## Triage notes

2026-11-18: a throwaway test built `PaneControlMark(access: .disconnected, driver: .none, owner: nil,
inUnownedGroup: false, controllers: ["script (pid 1)"], savedIntent: nil, revokeAvailable: true)`. `isShown` returned
false. `controlMark(for:)` fills `controllers` from `controllers(of:)`, which includes connections acting from the pane,
so the live app builds such a mark. The running app was not driven. The throwaway test was removed.

Files the fix would touch: `Packages/UnitermKit/Sources/WindowKit/PaneFrameView.swift` and a test in
`Packages/UnitermKit/Tests/WindowKitTests`.
