# Tabs past the tab bar's trailing edge cannot be seen or clicked

**Status:** open
**Validation:** found by reading the code during the UTERM-041 review, not reproduced in the app.
**Found:** 2026-11-21, during the UTERM-041 review

## Observed

A terminal or browser pane with more tabs than fit its width lays the extra tabs out past the bar's trailing edge.
They cannot be seen or clicked. Selecting one from the keyboard or the palette does not bring it into view.

## Cause

- `AppletTabBar.layout` (`Packages/UnitermKit/Sources/AppletKit/AppletTabBar.swift`, about line 178) gives each tab
  at least 80 points and places tabs one after another, past the bar's width when they do not fit.
- The bar does not scroll, and it has no overflow menu.

## Repro

In a browser pane about 500 points wide, open 8 tabs. Expected: every tab is reachable in the bar. Actual: about 5
tabs show, and the rest are cut off at the bar's edge.

## Fix

Make every tab reachable in the bar. That needs a design call:

- Scroll the bar, and scroll the selected tab into view.
- Add an overflow control at the trailing end that lists the tabs past the edge.
- Shrink tabs below 80 points before either, down to a floor that keeps the marker slot whole.

## Workarounds

Switch tabs from the keyboard or the palette. The selected tab's content shows, though its tab stays out of view.
