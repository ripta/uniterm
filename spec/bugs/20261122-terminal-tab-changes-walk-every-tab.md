# A terminal pane walks every tab at each title change and tab switch

**Status:** fixed 2026-11-23, for the switch and resize walks. The title array and the published list stay with
UTERM-053 M1, and the lookups by tab ID with UTERM-058 M2.
**Fixed:** 2026-11-23
**Estimate:** small to medium; the one non-trivial decision, how a resize reaches every live session, was settled by
the user: a session area view.

## Observed

A terminal pane holds many tabs. A program in one tab sets its title often through OSC. Each title change walks every
tab of the pane several times on the main thread. Each tab switch, open, and close also walks every tab.

Each shell tab holds a pty, which limits a shell pane's count. A restored program-mode pane holds no session per
waiting tab, so a stored layout can carry any number of them.

## Cause

- A title change in `handle(_:in:)` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`) maps every
  tab's title and hands the array to the tab bar. It then reports a tab change to the host.
- The host reads the applet's published tabs at each report. The terminal's `publishedTabs` is computed. Each read
  builds every `AppletTab`, then the list, whose init scans every tab for the selection.
- `refreshTabs` ran on every select, open, close, and reopen. It called `setVisible` on every session, and
  `setFocused(false)` on every hidden one.
- `layoutContents` set a frame on every session view. It runs at each resize, and at each link hover through
  `updateLinkPreview`.
- A lookup by tab ID scans the tabs. `selectTab(id:)` runs `firstIndex` over every tab, and the published list's
  `contains` scans it too. The palette's `chooseTab` and scripting's tab lookups in `WindowScripting.swift` reach both.
  UTERM-058 M2 fixes these lookups with a map from ID to tab.
- ADR-08 allows only local work whose duration uniterm bounds on the main thread. The terminal has no tab cap.

## Repro

Confirmed by reading the code on 2026-11-23, then pinned by a package test. In a pane of 5 shell tabs, one switch
touched all 5 sessions, and closing a tab that was not shown touched every remaining session.

## Fix

The applet now remembers the tab and the session view that showed at the last refresh. A refresh hides only that tab
and shows only the selected one. A new session starts hidden, unfocused, and not visible, and the next refresh shows it
when its tab is selected. A tab's link hover is cleared when it hides and again when it shows, so a hover that arrived
while it was hidden is not trusted.

Session views now live in one area view sized to the content rect. Each fills it through its autoresizing mask, so
AppKit resizes every live session, hidden ones included, and `layoutContents` sets one frame. Hidden tabs keep tracking
the pane's size, as before. The cost of a resize follows the live sessions, which ptys bound, not the tab count.

Files changed:

- `Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`
- `Packages/UnitermKit/Tests/TerminalAppletTests/TerminalAppletTests.swift`: the regression test
  `testASwitchTouchesOnlyTheTabsThatChangeVisibility`, and the layout test now also checks the hidden session's size
- `UITests/TabsUITests.swift`: `testAHiddenTabsShellSeesTheWindowSize` checks in the real app that a hidden tab's shell
  sees a window resize

Still open, owned elsewhere: the title array in the title-change handler and the computed published list belong to
UTERM-053 M1. The lookups by tab ID belong to UTERM-058 M2.
