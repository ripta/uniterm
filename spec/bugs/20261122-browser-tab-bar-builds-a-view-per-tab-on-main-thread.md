# The browser's tab bar builds and updates one view per tab on the main thread

**Status:** proposed, see [UTERM-053](../proposals/UTERM-053-browser-tab-work-never-grows-with-the-tab-count-on-the-main-thread.md)
**Triaged:** 2026-11-22 (still reproduces; proposal filed)
**Found:** 2026-11-22, while measuring the restore for the UTERM-051 review
**Estimate:** large; two non-trivial decisions, how the bar bounds its items versus a tab cap, and how `refresh` updates only changed tabs. See "Fix".

## Observed

A browser pane of 10,000 tabs takes about 1.8 s to restore on the main thread, in a debug build. The tab bar's first
update takes about 1.2 s of that. At 50,000 tabs the restore takes about 11 s.

Every later refresh still walks every tab. At 10,000 tabs, an update that changes only the selection takes about 64 ms
in the bar. Computing the titles takes about 99 ms more. A refresh follows each load state and title change, and a page
chooses how often its title changes.

## Cause

`AppletTabBar.update` (`Packages/UnitermKit/Sources/AppletKit/AppletTabBar.swift:164`) keeps one `AppletTabItem` view
per title. It creates the missing ones, then sets the index, title, selection, and both closures on every item.
`BrowserApplet.refresh` (`Packages/UnitermKit/Sources/BrowserApplet/BrowserApplet.swift:1434`) computes every tab's
title and calls it on each refresh. The private init cleans every title for `publishedTabs`, then calls `refresh`,
which cleans them all again.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound.

## Repro

A throwaway package test built 10,000 `BrowserDescription.Tab` records, then timed `AppletTabBar.update` on a fresh bar
twice and `BrowserApplet(restoring:)` once. Debug build: 1,187 ms for the first update, 64 ms for the second, and
1,809 ms for the whole restoring init. Tab objects alone took 7 ms. Expected: a restore and a refresh whose main-thread
cost does not grow with the tab count.

## Fix

Not settled. The bar is one of three per-tab costs on the main thread. `refresh` also cleans every title and rebuilds
the published tab list and its change snapshot from every tab. The restoring init also makes one tab object per
record, which is cheap at 7 ms for 10,000 tabs. A fix that bounds only the bar leaves `refresh`'s walk unbounded.

The design call is how the pane bounds its per-tab work:

- Show only the items that fit, and reuse them as the user scrolls or the selection moves. The bar already caps each
  item's width at a narrowest size, so only a bounded number can be visible. `refresh` then also needs to update only
  the tabs that changed, and to clean titles once per change instead of once per refresh.
- Cap the tabs per pane. That brings in a product limit and a rule for stored panes over the cap.

Bug `20261121-tab-bar-overflow-hides-tabs` changes the same bar's layout, so the two fixes bear on each other.

UTERM-051 moves the layout decode off the main thread. That leaves this cost on the main thread at launch.

## Investigation notes

Triage run on 2026-11-22.

- The code still matches the cause above.
- A throwaway package test with 10,000 tabs in a debug build measured 1.17 s for the bar's first update, 61 ms for a
  selection-only update, and 1.63 s for the restoring init. The report's numbers hold. The test was not kept.
