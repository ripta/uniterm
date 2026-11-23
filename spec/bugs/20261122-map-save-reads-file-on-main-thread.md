# Saving a map reads its file on the main thread

**Status:** open
**Validation:** not confirmed; found by reading the code during the UTERM-050 review. The hang needs a mount that stops
answering.

## Observed

A user saves a map whose file sits on a network share that has stopped answering. The save is reached from Cmd-S or
from Save in the question a pane close, window close, or quit asks. The app may freeze until the mount times out.

## Cause

- `performSave` in `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift` (about lines 987-996) runs on
  the main actor. Before it writes, it calls `resolvingSymlinksInPath()` and `Data(contentsOf:)` on the file's path, to
  compare the file on disk with the last saved copy.
- The write itself already runs off the main thread, in `atomicWrite`, which is `@concurrent`.
- ADR-08 asks for main-thread work whose duration uniterm bounds. A read from a network path has no bound.

## Repro

Open a map from a network share, edit a pin, then make the server unreachable so the mount hangs. Press Cmd-S.
Expected: the app stays responsive and the save reports its outcome later. Suspected actual: the app stops responding
until the mount times out.

## Fix

Move the conflict read off the main thread beside the write, and bring its result back to the main actor before the
conflict question. The flow is already `async`. No design call is known. UTERM-050 covers the save panel's start
folder, not this read.
