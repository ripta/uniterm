# A controller package read that never returns leaves its admission pending forever

**Status:** open
**Validation:** not confirmed; traced only. A repro needs a mount whose reads never answer, such as a stalled FUSE or
network volume.
**Found:** 2026-11-23, by the design critic reviewing UTERM-057

## Observed

`uniterm run <folder>` and `uniterm controller run <folder>` ask the app to admit a package. The app reads the package
off the main actor with no deadline. When the folder sits on a mount whose reads never return, the admission never
finishes. The command waits forever. The connection stays in the app's pending admissions. One cooperative-pool thread
stays blocked in the read. A handful of such runs could starve other detached work in the app.

## Cause

1. `ScriptControllers.swift:75` records the admission, then `:80-82` runs `Self.admit` in `Task.detached` and awaits
   it with no timeout.
2. `admit` calls `ControllerSnapshot.create`, which opens, walks, and copies the program-chosen folder with blocking
   `openat` and `read` calls (`Packages/UnitermKit/Sources/ControllerPackage/ControllerSnapshot.swift:97`, `:275`,
   `:327-350`).
3. Nothing cancels the read when the command disconnects.

## Repro

Not run. Expected repro:

1. Put a controller package on a FUSE mount whose `read` never returns.
2. Run `uniterm run <that folder>`.
3. Expected: the run is refused after a bounded wait. Actual, per the trace: the command hangs, and the admission stays
   pending after the command is killed.

## Fix

Shares a design call with [UTERM-057](../proposals/UTERM-057-package-read-by-invoker.md). When the command reads the
package and sends its bytes, the app never reads a program-chosen file system, and this bug goes away. When the app
keeps reading a folder or a passed descriptor, the read needs a bound. Blocking reads cannot be cancelled from Swift, so
that bound means a thread the app abandons, or a separate process.
