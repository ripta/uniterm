# The palette rebuilds and filters every tab of every pane while it shows

**Status:** open
**Estimate:** large; two non-trivial design decisions. See "Estimate notes".
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

## Estimate notes

Traced on 2026-11-23 against the current code. `tabCandidates(target:)` loops over every pane and every tab of
`publishedTabs.all`. It neutralizes each title and detail and builds a `PaletteEntry` for each. It then builds a `Set`
of keys and runs `firstIndex` on the recency list for each tab. `schedulePaletteRefresh` bounds the rebuilds to one per
interval, not the work in each. The cost was not measured.

No accepted proposal owns the fix. The browser tab-count proposal rules the palette out of its scope and points at this
bug.

Decisions that are not trivial:

- Whether to bound the candidates a rebuild and a filter visit, which changes what the palette lists for a pane with
  many tabs, or to keep every tab listed and add an incremental index.
- For an incremental index, the per-tab change report is a new host contract that every applet must implement.

The fix would touch `MainWindowController+Palette.swift`, `PaletteListing`, the applet tab-list contract, and every
applet that publishes tabs.
