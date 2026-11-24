# Saving a map reads its file on the main thread

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23
**Estimate:** small; one design decision, resolved on 2026-11-23: what Save does when the pane changes during the
off-main read. Save gives up when the open generation, the path, or `closed` changed. Opening another file, clearing the
file, and closing the pane each ask the user to discard the edits first, so finishing would write edits the user gave
up.

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

## Fix note

Triaged and fixed on 2026-11-23. The trace held: `performSave` resolved the path's links and read the file inline on
the main actor. The hang itself was not reproduced, since it needs a mount that stops answering.

Save now resolves and reads the file in `readSavedFile`, which is `@concurrent`, beside `atomicWrite`. It reaches the
read through `readOnDisk`, which tests replace. After the read, Save returns false without asking or writing when
another file opened, the file was cleared, or the pane closed.

Files: `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet.swift`, and
`testSaveWritesNothingWhenItsEditsAreDiscardedDuringItsRead` in
`Packages/UnitermKit/Tests/MapViewerAppletTests/MapPinEditingTests.swift`. The test holds the read open, opens another
file, and discards the edits. Before the fix, Save read the file inline, returned true, and wrote the edits. The test
cannot prove the default reader leaves the main thread. `@concurrent` carries that, as it does for the write.
