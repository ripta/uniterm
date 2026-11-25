# A window's script tab numbers keep an entry for every tab ever seen

**Status:** open
**Validation:** not confirmed; traced by reading the code during the UTERM-058 review. Whether the growth is intended is
not known.
**Estimate:** small; no design decision. See "Estimate notes".

## Observed

A script lists the tabs of a pane that opens and closes tabs all day, such as a controller-driven browser pane. Each
tab the script sees gets a number. The window keeps that number, in both directions, after the tab closes. The two maps
grow with every tab a script has ever seen in the window, for the window's lifetime.

## Cause

- `ScriptTabNumbers` (`Packages/UnitermKit/Sources/WindowKit/WindowIDSource.swift`, about lines 69-87) adds a pair to
  `numbers` and `tabs` the first time a script sees a tab. Nothing removes a pair.
- Its doc comment says a number "that names a closed tab names nothing, never another tab". That holds because numbers
  only grow. It does not need the closed tab's pair to stay.

## Repro

None run. Suggested: in one window, open and close 100,000 tabs while a script lists the pane's tabs after each open.
Expected: memory for the numbers stays proportional to the open tabs. Suspected actual: it grows with every tab ever
listed.

## Fix

Drop a tab's pair when the tab closes or its pane leaves the window. `last` keeps growing, so a number is still never
reused, and a closed tab's number still resolves to nothing.

## Estimate notes

Traced on 2026-11-23 by reading the code. Nothing was run. The fix needs a close signal per tab, or a prune against the
window's live tabs at each script call that names one. The prune at each call walks every tab, so the close signal is
the one that fits ADR-08. Tab IDs are never reused, per UTERM-002, so a pruned ID never comes back to claim a new
number.
