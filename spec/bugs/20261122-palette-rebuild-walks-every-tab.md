# The palette rebuilds and filters every tab of every pane while it shows

**Status:** open
**Validation:** not confirmed; traced by reading the code during the UTERM-053 review. The cost was not measured.

## Observed

The command palette shows while a background page in a large browser pane changes its title in a loop. Each change
schedules a palette rebuild. Each rebuild walks every tab of every pane on the main thread. Each keystroke in the
palette filters every candidate.

## Cause

- `schedulePaletteRefresh` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController+Palette.swift`, about lines
  166-176) coalesces rebuilds to at most one per 100 ms while the palette shows.
- Each rebuild (about lines 132-162) walks every tab of every pane. It neutralizes each title and detail, and looks the
  tab up in the recency list.
- Each keystroke filters every candidate.
- `chooseTab` (about line 204) and scripting's tab lookups (`WindowScripting.swift`, about lines 546 and 795) scan the
  published list once per call.
- ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap.

## Repro

None run. Suggested: open a browser pane of 10,000 tabs, show the palette, and have a background page set its title on
a timer. Time each rebuild and each keystroke's filter. Expected: a cost that does not grow with the tab count.
Suspected actual: up to 10 full rebuilds a second, and a linear filter per keystroke.

## Fix

UTERM-053 keeps this out of its scope. A fix needs a design call: an incremental palette index fed by per-tab change
reports from every applet, which adds a host contract, or a bound on how many candidates a rebuild and a filter visit.
