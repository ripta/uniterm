# Closing a browser pane encodes every tab's history on the main thread

**Status:** open
**Found:** 2026-11-22, during the design review of UTERM-052
**Validation:** mechanism confirmed by reading the code. Cost not measured.

## Observed

Closing a browser pane puts its description on the undo stack. Building that description reads and encodes every tab's
WebKit history on the main thread. The wait grows with the tab count and with each tab's history.

## Cause

`describeAndClose` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1086`) calls `describe()`, which
calls `undoPart()` (`Packages/UnitermKit/Sources/BrowserApplet/BrowserApplet.swift:400`). That maps every tab's
`interactionData` and runs `JSONValue(encoding:)` over the whole undo state. The encode base64-encodes each history blob
and parses the result back.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound.

UTERM-052 makes the save ask for the saved description alone. The close then becomes the only caller of the undo part.
It also takes on the live WebKit reads that saves pay today, for each tab whose history changed since its last read.

## Repro

Not run. Expected: closing a pane of 10,000 loaded tabs does not hold the main thread for a time that grows with the
tab count. UTERM-052 M1 records the close's cost at 1,000 and 10,000 loaded tabs.

## Fix

Not settled. It needs a design call:

- Keep each tab's encoded undo entry current at each history change, so the close only wraps the kept array. That moves
  a WebKit read and an encode to each history change, at a rate a page chooses, and adds an index alignment between the
  entries and the tabs.
- Build the undo part off the main thread from the tabs' history data. The tabs drop their history at close, so the data
  must be taken before the close.

Bug `20261122-undo-reopen-decodes-pane-on-main-thread` tracks the decode on the way back.
