# A dirty map pane base64-encodes its whole document at every save and change check

**Status:** open
**Found:** 2026-11-22, during the design review of UTERM-052
**Validation:** mechanism confirmed by reading the code. Cost not measured.

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
