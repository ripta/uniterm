# A dirty map pane base64-encodes its whole document at every save and change check

**Status:** proposed. The fix is a check of [UTERM-052](../proposals/UTERM-052-browser-description-never-encodes-tabs-on-the-main-thread.md) M2.
**Found:** 2026-11-22, during the design review of UTERM-052
**Estimate:** small; no open design decisions. Blocked on UTERM-052 milestone M2, which adds the contract call for the
saved description alone. That milestone is not started, so no fix can land yet. Once it lands, the map overrides the
call to return its payload description without `undoOnlyPart()`. The files are
`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift` and a test in the map applet's test target that
shows the saved description equals `describe()` without its undo part, and that a dirty pane's saved description
builds no undo part. The choice to override per applet instead of splitting the contract is settled in UTERM-052.

## Observed

A map pane with unsaved edits encodes its whole edited document, and the bytes it was edited over, every time the
window asks for its description. The window asks at every change the pane reports, and at every save. Both drop the
result, since a layout file never holds the undo part.

## Cause

`MapViewerApplet.describe` (`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift:651`) always calls
`undoOnlyPart()` (`:1150`). For a dirty pane, that calls `undoState(document:base:path:)` (`:1136`), which
base64-encodes the document and its base. The save calls `describe()` and drops the undo part (`savedNode`,
`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1338`). So does the change check
(`notifyLayoutIfDescriptionChanged`, `:1371`). Only a pane close keeps it (`describeAndClose`, `:1086`).

The map document has a size bound, so the work is bounded. It is wasted on every call but the close.

## Repro

Not run. Expected: a save of a dirty map pane does no work in step with the document's size.

## Fix

UTERM-052 adds a contract call for the saved description alone, whose default drops the undo part from `describe()`.
The map could answer that call without building its undo part, and the window's change check calls it too. That needs
no design call once UTERM-052 lands. Splitting the contract so `describe()` returns only the saved part would cover
every applet. It was weighed in UTERM-052 as a scope addition.

## Triage

Triaged on 2026-11-23. The trace still holds: `describe()` calls `undoOnlyPart()` at `MapViewerApplet.swift:651`. The
save's `savedNode` (`MainWindowController.swift:1340`) and `notifyLayoutIfDescriptionChanged` (`:1375`) still call
`describe()` and drop the undo part. No saved-description call exists yet. UTERM-052 M2 is not started.

The user chose to add the map's answer to UTERM-052 M2, as a scope addition. "The save asks for the saved description
alone" now says the map answers the call, and M2 gained a map check. The check also covers an undo reopen of a dirty
map pane.
