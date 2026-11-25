# A terminal pane walks every tab at each title change and tab switch

**Status:** open
**Validation:** not confirmed; traced by reading the code during the UTERM-053 review. The cost was not measured.

## Observed

A terminal pane holds many tabs. A program in one tab sets its title often through OSC. Each title change walks every
tab of the pane several times on the main thread. Each tab switch, open, and close also walks every tab.

Each shell tab holds a pty, which limits a shell pane's count. A restored program-mode pane holds no session per
waiting tab, so a stored layout can carry any number of them.

## Cause

- A title change in `handle(_:in:)` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`, about line 767)
  maps every tab's title and hands the array to the tab bar. It then reports a tab change to the host.
- The host reads the applet's published tabs at each report. The terminal's `publishedTabs` is computed (about line
  302). Each read builds every `AppletTab`, then the list, whose init scans every tab for the selection.
- `refreshTabs` (about lines 714-738) runs on every select, open, and close. It calls `setVisible` on every session,
  and `setFocused(false)` on every hidden one.
- `layoutContents` (about lines 749-753) sets a frame on every session view.
- ADR-08 allows only local work whose duration uniterm bounds on the main thread. The terminal has no tab cap.

## Repro

None run. Suggested: restore a program-mode pane of 10,000 waiting tabs and one running program that sets its title in
a loop. Time the main thread per title change. Expected: a cost that does not grow with the tab count. Suspected
actual: three walks over every tab per change.

## Fix

UTERM-053 changes the shared tab bar's input, which removes the per-change title array. That proposal keeps the rest
out of its scope. The rest needs a design call: cache the published list and update it per change, or keep it computed
and accept a cheap walk. Keeping the hidden sessions' visibility untouched on a switch means tracking the previous
selection.
