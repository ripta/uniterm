# A map's file-change check reads the whole file on the main thread

**Status:** open
**Found:** 2026-11-23, by the triage of the map save read bug during a bug sweep
**Validation:** not confirmed; traced by reading the code. The hang needs a mount that stops answering.

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
