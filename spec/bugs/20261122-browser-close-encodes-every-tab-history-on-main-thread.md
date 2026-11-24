# Closing a browser pane encodes every tab's history on the main thread

**Status:** fixed 2026-11-23
**Found:** 2026-11-22, during the design review of UTERM-052
**Fixed:** 2026-11-23
**Estimate:** medium; settled by measurement. The user chose to drop the conversion instead of either option below,
once triage found the undo part never leaves memory.

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

## Options at filing

These were the options before triage found the conversion was not needed:

- Keep each tab's encoded undo entry current at each history change, so the close only wraps the kept array. That moves
  a WebKit read and an encode to each history change, at a rate a page chooses, and adds an index alignment between the
  entries and the tabs.
- Build the undo part off the main thread from the tabs' history data. The tabs drop their history at close, so the data
  must be taken before the close.

Bug `20261122-undo-reopen-decodes-pane-on-main-thread` tracks the decode on the way back.

## Triage 2026-11-23

Measured with a scratch test against real WebKit tabs, in a debug build. Tabs past 100 were restored tabs that hold a
real history record and no page, since 10,000 live pages do not fit in memory. A restored tab skips the WebKit read, so
those rows show the conversion alone.

| Tabs | History per tab | Close before | Close after |
|------|-----------------|--------------|-------------|
| 100 loaded | 3 pages | about 3 ms | about 4 ms, cold |
| 1,000 | 3 pages | 29 ms | 18 ms |
| 10,000 | 3 pages | 277 ms | 171 ms |
| 10,000 | 20 pages | 518 ms | 164 ms |

At 100 loaded tabs the WebKit reads cost about as much as the conversion, about 0.015 ms a tab each. The undo part
never leaves the process. A layout file never holds it. Yet each close converted every tab's record to base64 JSON and
parsed it back, and each reopen undid that.

## Fix

The description's undo-only part now holds the applet's own value, unconverted (`AppletUndoState` in
`AppletKit/AppletDescription.swift`). The browser stores its undo state as is, so a close no longer grows with history
length. The terminal, map, and text viewer keep their JSON values inside the new holder, unchanged.

What the close still does per tab: one WebKit history read and the tab record's encode for the saved part. UTERM-052
owns the saved part. The read is about 0.015 ms a tab.

Regression test: `BrowserReopenTests.testTheUndoPartHoldsEachTabsHistoryRecordUnconverted`. It failed before the fix
with the history held as a base64 JSON string. It proves the conversion is gone, not how long a close takes.
