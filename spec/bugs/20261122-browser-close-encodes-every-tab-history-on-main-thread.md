# Closing a browser pane encodes every tab's history on the main thread

**Status:** open
**Found:** 2026-11-22, during the design review of UTERM-052
**Estimate:** medium; two non-trivial design decisions. First, keep each tab's encoded undo entry current at each history
change, or capture the history data before the close and encode it off the main thread. The first adds a WebKit read and
an encode at a rate a page chooses, and an index alignment. The second changes the close from a synchronous push to the
ledger to an asynchronous one, so a quit or an immediate undo reopen needs the payload at once. Second, whether the
close may wait on the first, since UTERM-052 leaves this bug open on purpose and no accepted proposal owns the fix. The
fix would touch `BrowserApplet.swift`, `BrowserTab.swift`, and possibly `MainWindowController.swift` and the ledger.
Re-triaged 2026-11-23: traced against the current code, where `undoPart()` still maps every tab's `interactionData` and
encodes the whole state at a close. The cost is not measured. UTERM-052 M1 records it.

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

Today a save fills the applet's undo cache and each tab's kept history read. So a pane that sat quiet for a second
closes without reading or encoding any history. UTERM-052 makes the save ask for the saved description alone. The close
then becomes the only caller of the undo part, and nothing fills either cache before it. A quiet pane's close then reads
and encodes every loaded tab's history, so it gets slower than today.

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
