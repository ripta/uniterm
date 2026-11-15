# The launcher's rows end short of the filter box while a legacy scroller shows

**Status:** open
**Estimate:** small; one design decision

## Observed

On a Mac that shows legacy scrollers, a launcher pane too short for its list shows a 17-point scroller beside the list.
The rows and the command box end at the scroller's left edge. The title, the subtitle, and the filter box still end at
the card's right edge. So the list's right edge sits 17 points left of the filter box's.

`testTheLauncherPartsShareOneLeftEdge` states the opposite contract: every part shares one right edge
(`Packages/UnitermKit/Tests/WindowKitTests/LauncherTests.swift`). It passes only because it runs with overlay scrollers,
the default on a Mac with a trackpad.

Seen in layout frames while fixing the legacy-scroller layout conflict on PR 45. At a 200 by 100 pane, the scroll view
was 168 points wide and its clip view 151. Not covered by a test.

## Cause

The list's document is pinned to the clip view (`LauncherView.swift`, `buildListScroll`). A legacy scroller takes its
width from the clip view, and the parts outside the scroll view do not move.

## Repro

In the tiny-pane layout test's style, set `scrollerStyle = .legacy` on the launcher's scroll view before its first
layout. Lay it out at 200 by 100 with the program row chosen, then compare a row's right edge with the filter box's.

- Expected, per the shared-edge contract: the edges match.
- Actual: the row ends 17 points short.

## Fix

This needs a design call. The candidates:

- Accept the gap as the platform's normal look. Narrow the shared-edge test's contract to say so, and add a
  legacy-style case that pins it.
- Keep the list's scroller as an overlay whatever the system setting, so every part keeps one right edge. That
  overrides the user's "Show scroll bars: Always" choice for this one list.
- Inset the parts outside the list by the scroller's width while it shows, so every edge moves together.
