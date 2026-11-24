# A map's file-change check reads the whole file on the main thread

**Status:** fixed 2026-11-24
**Found:** 2026-11-23, by the triage of the map save read bug during a bug sweep
**Fixed:** 2026-11-24
**Estimate:** small; no open design decisions. A late result is dropped by Save's own check. One read runs at a time
per pane, since that bounds the reads a dead mount parks. The read runs on a dispatch queue, as the terminal's
link-click check does, so a parked read holds no cooperative-pool thread.

## Observed

A map pane watches its file. Each time the watcher fires, including right after the map's own save, the pane reads the
whole file to compare it with its last saved copy. On a network share that stops answering, the app may freeze until
the mount times out. A large map file also costs a full read on the main thread at each change.

## Cause

- `fileChangedOnDisk()` in `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift` (about line 1116) runs
  on the main actor. The watcher installed by `watch(_:)` calls it.
- It calls `Data(contentsOf:)` on the file's path inline (about line 1119), then compares the bytes with
  `savedDocument`.
- ADR-08 asks for main-thread work whose duration uniterm bounds. A read from a network path has no bound.
- Neither UTERM-050 nor UTERM-051 names this read. The map save read bug covers only the read inside Save.

## Repro

Open a map from a network share, then make the server unreachable so the mount hangs. Touch the file from another
machine, or save the map. Suspected actual: the app stops responding until the mount times out.

## Fix

Read off the main thread and bring the result back before the dirty check. The pane may change while the read runs:
another file opens, the file is cleared, or the pane closes. What a late result does then is a design call. It is the
same question the map save read bug's estimate names, so the two likely share one answer.

## Fix note

Triaged and fixed on 2026-11-24. The trace held. The hang itself was not reproduced, since it needs a mount that stops
answering. A package test reproduced the inline read: with the injected reader held open, the change check still read
the file and reloaded the pane, and it never called the reader.

The change check now reads through the same reader as Save, off the main thread. One read runs at a time. A change
during the read asks for one more read when it returns, so the newest file on disk is what the pane compares. A result
that lands after another file opened, the file was cleared, or the pane closed is dropped.

Found along the way: Save's read and write were `@concurrent`, so a dead mount parked a Swift cooperative-pool thread.
Both now run on a dispatch queue. That part landed in its own commit, without a regression test, since no test can tell
a pool thread from a queue thread.

Files: `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift`, and
`testAChangeCheckReadsThroughTheReaderOneReadAtATime` in
`Packages/UnitermKit/Tests/MapViewerAppletTests/MapPinEditingTests.swift`. Existing change-check tests in that file and
in `MapAlertsTests.swift` now wait for the check's read. The held read stands in for the hung mount, so the test cannot
prove the default reader leaves the main thread.
