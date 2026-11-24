# A map saved through a symlink stays unsaved

**Status:** fixed 2026-11-24
**Found:** 2026-11-23, by the design review of the map save read bug during a bug sweep
**Fixed:** 2026-11-24
**Estimate:** small; no open design decisions. Save hands the write the pane path it started from, which keeps the
write's guard against a pane that moved to another file.

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

## Fix note

Triaged and fixed on 2026-11-24. `testSaveThroughASymlinkKeepsTheLink` now also checks that the saved pane is clean,
and that a second Save asks nothing about a change on disk. Before the fix, the pane stayed edited, and the second Save
asked about the map's own write.

Save now passes the write the pane's own path it started from, and the write records the saved bytes when the pane
still shows that path. The resolved target is no longer compared with the link's path. Save As passes no path, since
it records its bytes once the pane takes the new file.

Files: `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift`, and the test in
`Packages/UnitermKit/Tests/MapViewerAppletTests/MapPinEditingTests.swift`. Not checked in the running app.
