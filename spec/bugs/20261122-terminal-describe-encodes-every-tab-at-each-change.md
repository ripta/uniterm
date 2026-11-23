# The terminal encodes every tab and closed tab on the main thread at each change

**Status:** open
**Found:** 2026-11-22, during the design review of UTERM-052
**Validation:** mechanism confirmed by reading the code. Cost not measured.
**Estimate:** medium; three non-trivial design decisions. See "Estimate notes".

## Observed

The window asks a terminal pane for its description at every change the pane reports. Each call encodes every tab's
directories and every closed tab on the main thread. The pane reports a change when the selected tab's title changes,
and when a tab's directory changes. A program sets both, so a program chooses how often the pane pays. The cost grows
with the tab count.

## Cause

`TerminalApplet.describe` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift:454`) builds a
`TerminalDescription` from every tab and calls `appletDescription(closedTabs:)`
(`Packages/UnitermKit/Sources/TerminalApplet/TerminalDescription.swift:48`). That runs `JSONValue(encoding:)` over the
payload and over the closed tabs. The reports come from `handle(_:in:)` (`TerminalApplet.swift:760`). The window's
change check calls `describe()` at every report
(`notifyLayoutIfDescriptionChanged`, `Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1371`).

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap. A shell tab holds
a pty, which limits a shell pane's count. A restored program-mode pane holds no session per waiting tab, so a stored
layout can carry any number of them.

Bug `20261122-terminal-tab-changes-walk-every-tab` covers the same pane's other walks per change: the tab bar's titles,
the published tabs, and the visibility pass. This bug covers only the description.

## Repro

Not run. Expected: a directory change in one tab of a pane with many tabs costs the main thread no more than in a pane
with one tab.

## Fix

Not settled. UTERM-052 gives the browser an optional saved-state revision and a call for the saved description alone.
The terminal could adopt both. Whether it is worth it depends on a measurement at a realistic tab count.

## Estimate notes

Triaged by reading the code on 2026-11-23. The mechanism still holds. `TerminalApplet.describe` maps every tab into a
`TerminalDescription` and encodes it, plus every closed tab, at each call. The window's change check calls it at each
report. Not reproduced and not measured. The build passes.

No accepted proposal owns the terminal's fix. UTERM-052 settles the browser only. Its "Leaves undone" lines name the
terminal's description as untouched, and its scope-addition note excludes the terminal's undo part. UTERM-051 and
UTERM-053 do not cover the terminal.

The fix would adopt two things UTERM-052 adds to the applet contract: an optional saved-state revision and a call for the
saved description alone. UTERM-052 M1 and M2 are both NOT STARTED. Neither exists in the code today. No fix can land
until M2 does.

Design decisions the fix forces:

1. Whether the terminal adopts the revision, the saved-description call, or both. The saved-description call alone drops
   only the closed-tab encode. Every tab's directories are still encoded at each change check. Only the revision removes
   the per-change walk. Adopting both widens UTERM-052's scope to a second applet, which needs the user's approval.
2. Where the revision moves. The sites are each tab's directory report, the selected tab's title change, and tab
   insert, remove, select, and reorder. A missed site silently skips a layout save. The choice between a counter at each
   site and a cached per-tab record, as the browser does, is a judgment call.
3. Whether to fix it at all before a measurement at a realistic tab count. The report says the cost is unmeasured, and a
   shell pane's tab count is bounded by its ptys. Only a restored program-mode pane can hold many tabs.

Files the fix would touch: `Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`,
`Packages/UnitermKit/Sources/TerminalApplet/TerminalDescription.swift`, and a test in the terminal applet's test target.
