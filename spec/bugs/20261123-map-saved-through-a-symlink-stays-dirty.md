# A map saved through a symlink stays unsaved

**Status:** open
**Found:** 2026-11-23, by the design review of the map save read bug during a bug sweep
**Validation:** reproduced in a package test. A temporary `XCTAssertFalse(applet.isDirty)` at the end of
`PinEditReviewTests.testSaveThroughASymlinkKeepsTheLink` failed. Not checked in the running app.

## Observed

A user opens a map through a symbolic link, adds a pin, and saves. The save writes the target file and keeps the link.
The pane still reads as edited. The next Cmd-S raises the "changed on disk" question for a change the map made itself.
Quit and close also ask to save work that is already saved.

## Cause

- `performSave` in `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift` (about line 994) resolves the
  path through symlinks and writes to the resolved URL.
- `write(_:to:)` (about line 1055) sets `savedDocument` only when `url.path == record.path`.
- For a pane opened through a link, `record.path` is the link's path. The two never match, so `savedDocument` keeps the
  old bytes and `isDirty` stays true.
- `testSaveThroughASymlinkKeepsTheLink` checks the link and the target's bytes, not `isDirty`, so it misses this.

## Repro

Run `make test-package-select PACKAGE_TESTS='PinEditReviewTests/testSaveThroughASymlinkKeepsTheLink'` with
`XCTAssertFalse(applet.isDirty)` added at the end. It fails.

## Fix

Compare against the path the save started from, not the resolved one. Or have `performSave` tell `write` that the
target is the pane's own file. The map save read bug moves the resolution off the main thread, so the two fixes touch
the same lines. No design call is known.
