# An edited map past 32 MiB saves, but cannot be reopened

**Status:** open
**Validation:** confirmed by tracing the code during the UTERM-040 review. Not reproduced in a test or the running app.
**Found:** 2026-11-21, during the UTERM-040 review of the map's caps

## Observed

UTERM-016 M1 says "Save can therefore never write bytes the map could not read". That holds for bytes that do not
parse. It does not hold for size. A document edited past the reader's 32 MiB byte bound reads back, saves, and then
fails to reopen with `tooLarge`.

## Cause

- The 32 MiB bound is checked only in `GeoJSONFileReader.bytes(of:limit:)`, which runs when a file is read from disk
  (`Packages/UnitermKit/Sources/MapViewerApplet/GeoJSONFileReader.swift:60`, `:74`).
- The read-back of an edited document goes through `layer(of:)` and `replaceDocument`
  (`MapViewerApplet.swift:862-930`). Neither checks size.
- `performSave` and `saveAs` do not check size either.

By hand it is hard to reach, since it takes many edits on a file near the bound. The file on disk stays intact, so
nothing is lost. The map simply refuses to open what it saved.

## Options

- Refuse any edit whose result would pass 32 MiB, before any effect, for every source. Undo and redo are never refused.
  UTERM-040's caps decision settles this for program and user edits alike, as an addition the user rules on at that
  proposal's review gate.
- Refuse at Save instead, and leave the edit in place. The user then holds unsaved work the map will not write.
- Raise the reader's bound. That moves the edge without closing it.

## Fix

Waits on UTERM-040's review gate. If the user keeps its caps decision, UTERM-040 M1 fixes this.
