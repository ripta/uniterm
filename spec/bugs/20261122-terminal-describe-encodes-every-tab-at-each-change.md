# The terminal encodes every tab and closed tab on the main thread at each change

**Status:** open
**Found:** 2026-11-22, during the design review of UTERM-052
**Validation:** mechanism confirmed by reading the code. Cost not measured.

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
