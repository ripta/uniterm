# Saving a map reads its file on the main thread

**Status:** open
**Estimate:** small; one non-trivial design decision, found by the design review on 2026-11-23: what Save does when the
pane changes during the off-main read. The read adds an unbounded wait between the decision to save and the conflict
check. During it the user can open another file, clear the file, or close the pane with Don't Save. "Abandon" returns
false without asking or writing when the open generation, the path, or `closed` changed. "Finish" captures
`savedDocument`, the name, and the target before the read and compares against the capture, as a write in flight
finishes today. Both are defensible, and they differ in what the user sees. Traced, not reproduced: the hang needs a mount that stops answering. The code path is confirmed. `performSave` is `async` but runs on the main actor, and `resolvingSymlinksInPath()` and `Data(contentsOf:)` run inline before the conflict check. No accepted proposal owns the fix. UTERM-050 and UTERM-051 cover other reads.
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
