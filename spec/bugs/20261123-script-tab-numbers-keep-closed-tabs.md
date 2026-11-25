# A window's script tab numbers keep an entry for every tab ever seen

**Status:** proposed. The pane-level half was fixed 2026-11-24.
[UTERM-058](../proposals/UTERM-058-palette-tab-work-on-the-main-thread.md) M2 closes the tab-level half.
**Estimate:** small for each half; no open design decisions. The tab-level half waits on UTERM-058 M2's remove report.
See "Triage notes".

## Observed

A script lists the tabs of a pane that opens and closes tabs all day, such as a controller-driven browser pane. Each
tab the script sees gets a number. The window keeps that number, in both directions, after the tab closes. The two maps
grow with every tab a script has ever seen in the window, for the window's lifetime.

## Cause

- `ScriptTabNumbers` (`Packages/UnitermKit/Sources/WindowKit/WindowIDSource.swift`, about lines 69-87) adds a pair to
  `numbers` and `tabs` the first time a script sees a tab. Nothing removes a pair.
- Its doc comment says a number "that names a closed tab names nothing, never another tab". That holds because numbers
  only grow. It does not need the closed tab's pair to stay.

## Repro

Confirmed on 2026-11-24 with a throwaway package test, through `list-panes` in a real window with fake applets:

1. List a pane's tabs, then close one tab in that pane. The closed tab's number still resolves to its tab ID.
2. List the tabs of a second pane, then close that pane. All three of its numbers still resolve to their tab IDs.

## Fix

Drop a tab's pair when the tab closes or its pane leaves the window. `last` keeps growing, so a number is still never
reused, and a closed tab's number still resolves to nothing.

### Pane-level half, fixed 2026-11-24

`ScriptTabNumbers` now records the pane each number was issued in. Both pane close paths drop that pane's entries, next
to the window's other per-pane records. A controller that opens, lists, and closes panes no longer grows the window's
numbers. Scripts see no change: a stale reference still gets "the tab is not open in that pane".

Files changed:

- `Packages/UnitermKit/Sources/WindowKit/WindowIDSource.swift`: the pane record and `forget(pane:)`
- `Packages/UnitermKit/Sources/WindowKit/WindowScripting.swift`: each number is issued with its pane
- `Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift`: `describeAndClose` and `discard` forget the pane
- `Packages/UnitermKit/Tests/WindowKitTests/WindowScriptingTests.swift`: the regression test
  `testClosingAPaneDropsItsTabNumbers`, which failed before the fix
- `Packages/UnitermKit/Tests/WindowKitTests/WindowIDSourceTests.swift`:
  `testForgettingAPaneDropsOnlyItsEntriesAndReusesNoNumber`

The launcher swap needs no drop. The launcher has no applet type declaration, so its pane is never remote-controlled. A
script can never see its tab, so the tab never gets a number.

### Tab-level half, open

A tab that closes in a pane that stays open keeps its entry until the pane leaves. This is the Observed case. The
window has no per-tab close signal. `appletTabsDidChange` says only that a pane's tabs changed.

UTERM-058 M2 gives that report a change value that names removed tabs by ID. The user chose to have M2 drop a removed
tab's number there. M2 carries the check.

## Triage notes

Triaged on 2026-11-24. The design calls were:

- The close signal comes from UTERM-058 M2's remove report. Diffing a pane's tabs at every report would add the
  per-report main-thread walk that UTERM-058 removes. A separate close callback would give one fact two vocabularies,
  which UTERM-058 rejected.
- Dropping a pair changes nothing a script sees. `locate` in `WindowScripting.swift` gives the same error for a number
  never issued and for a closed tab. The dispatcher's authority check re-resolves the tab before a command runs.
  Reopened tabs get new IDs in both the terminal and the browser, so a dropped number never needs to come back.
- No full-list report drops a numbered tab today. One-tab applets set a new tab ID only in their initializers. UTERM-058
  M2 reports the questions applet's placeholder swap by ID.
