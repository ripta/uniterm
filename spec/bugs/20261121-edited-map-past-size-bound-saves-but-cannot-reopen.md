# An edited map past 32 MiB saves, but cannot be reopened

**Status:** open
**Estimate:** small; the bound's value waits on UTERM-040 M1's measurement.
**Triaged:** 2026-11-22 (still reproduces by trace; fix stays with UTERM-040 M1)
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

## Investigation notes

Triage run on 2026-11-22.

- The trace still holds on the current code. `replaceDocument` hands the edited bytes to the read-back with no size
  check. `performSave` and `saveAs` only wait on that read-back through `readAccepts`. Only `GeoJSONFileReader.bytes`
  enforces `maxBytes`.
- No test covers an edit past the bound. `MapFileTests` covers only a file on disk past it.
- The fix is one size check before the edit applies. The bound's value is not settled. UTERM-040's review gate chose a
  bound that M1 measures over keeping 32 MiB. A fix now would pick that number early.
- UTERM-040 M1 is not started.

## Fix

Waits on UTERM-040's review gate. If the user keeps its caps decision, UTERM-040 M1 fixes this.
