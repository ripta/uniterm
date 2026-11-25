# A map pane encodes its undo part at every save and change check

**Status:** proposed
**Found:** 2026-11-22, during the design review of UTERM-052
**Triaged:** 2026-11-23
**Estimate:** small; no open design decisions. Fixed by UTERM-052 M2, which adds the contract call for the saved
description alone and the map's answer together. That milestone is not started, so no fix can land yet. The files are
`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift` and a test in the map applet's test target. The
choice to override per applet instead of splitting the contract is settled in UTERM-052.

## Observed

A map pane with unsaved edits encodes its whole edited document, and the bytes it was edited over, every time the
window asks for its description. A map pane holding program pins also encodes every command layer, dirty or not. The
window asks at every change the pane reports, and at every save. Both drop the result, since a layout file never holds
the undo part.

## Cause

`MapViewerApplet.describe` (`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift:655`) always calls
`undoOnlyPart()` (`:1168`). For a dirty pane, that calls `undoState(document:base:path:)` (`:1154`), which
base64-encodes the document and its base. For a pane with command layers, it also encodes them with
`JSONValue(encoding:)`. The save calls `describe()` and drops the undo part (`savedNode`,
`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1340`). So does the change check
(`notifyLayoutIfDescriptionChanged`, `:1375`). Only a pane close keeps it (`describeAndClose`, `:1088`).

The command layers are capped at 13 layers and 2,500 pins. An edited document has no enforced size bound. Bug
`20261121-edited-map-past-size-bound-saves-but-cannot-reopen` tracks that, and UTERM-040 M1 fixes it. The work is
wasted on every call but the close.

## Repro

Not run. Expected: a save of a dirty map pane does no work in step with the document's size.

## Fix

UTERM-052 M2 adds a contract call for the saved description alone, whose default drops the undo part from `describe()`.
The same milestone has the map answer that call with its payload description, without building its undo part. The
window's change check calls it too. The user chose to add the map's answer to M2 on 2026-11-23, as a scope addition.
Splitting the contract so `describe()` returns only the saved part would cover every applet. It was weighed in UTERM-052
as a scope addition.
