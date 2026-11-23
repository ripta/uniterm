# A terminal pane walks every tab at each title change and tab switch

**Status:** open
**Validation:** not confirmed; traced by reading the code during the UTERM-053 review. The cost was not measured.
**Estimate:** small to medium; one non-trivial design decision. See "Estimate notes".

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

## Estimate notes

Traced on 2026-11-23 by reading the code. Nothing was run, and the cost was not measured.

UTERM-053 is accepted and its M1 is not started. It owns the title array in the title-change handler and the computed
published list. It publishes a read-through list instead. This bug owns only the other two walks.

- `refreshTabs` calls `setVisible`, `setFocused(false)`, and clears `hoveredLink` on every tab. `setVisible` already
  returns early when the state is unchanged. A tab with no session, which is every waiting tab of a restored
  program-mode pane, costs one nil check. The walk could cover only the previous and the new selection. That needs the
  previous selection tracked, and it is not a design call.
- `layoutContents` sets a frame on every session view, hidden ones included. Bounding it to the selected session
  changes behavior a user can see. A hidden shell tab would keep its old size through a window resize. Its program
  would learn the new size only when the tab is shown again, or the show path would set the frame. Equally correct
  options exist: keep sizing hidden sessions, or size a session when it is shown.

Non-trivial decision: whether hidden sessions track the pane's size while hidden.

The fix would touch `Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift` and its tests. It should wait for
UTERM-053 M1, which edits the same functions.
