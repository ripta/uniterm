# A controller package read that never returns leaves its admission pending forever

**Status:** proposed. [UTERM-057](../proposals/UTERM-057-package-read-by-invoker.md) M1 closes it.
**Estimate:** large; no open design decisions. UTERM-057 settles them. See "Triage notes".
**Found:** 2026-11-23, by the design critic reviewing UTERM-057

## Observed

`uniterm run <folder>` and `uniterm controller run <folder>` ask the app to admit a package. The app reads the package
off the main actor with no deadline. When the folder sits on a mount whose reads never return, the admission never
finishes. The command waits forever. One cooperative-pool thread stays blocked in the read, even after the command is
killed. A handful of such runs could starve other detached work in the app.

## Cause

1. `ScriptControllers.swift:75` records the admission, then `:80-82` runs `Self.admit` in `Task.detached` and awaits
   it with no timeout.
2. `admit` calls `ControllerSnapshot.create`, which opens, walks, and copies the program-chosen folder with blocking
   `openat` and `read` calls (`Packages/UnitermKit/Sources/ControllerPackage/ControllerSnapshot.swift:97`, `:275`,
   `:327-350`).
3. Nothing cancels the read when the command disconnects. The connection's close does clear its pending admission
   (`ScriptControllers.swift:469`). A read that finishes after that has its snapshot removed (`:243`). The blocked
   thread is what stays.

## Repro

Not run. Expected repro:

1. Put a controller package on a FUSE mount whose `read` never returns.
2. Run `uniterm run <that folder>`.
3. Expected: the run is refused after a bounded wait. Actual, per the trace: the command hangs. After the command is
   killed, the app's read stays blocked on its thread.

## Fix

Shares a design call with [UTERM-057](../proposals/UTERM-057-package-read-by-invoker.md). When the command reads the
package and sends its bytes, the app never reads a program-chosen file system, and this bug goes away. When the app
keeps reading a folder or a passed descriptor, the read needs a bound. Blocking reads cannot be cancelled from Swift, so
that bound means a thread the app abandons, or a separate process.

UTERM-057 settled that call: the command reads the package and sends its bytes. Its M1 closes this bug, and the user
kept that at the proposal's review gate.

## Triage notes

Triaged on 2026-11-24 by reading the code. The mechanism still holds. Nothing in the admission path changed since the
bug was filed.

- `beginController` still runs `admit` in `Task.detached` and awaits it with no deadline
  (`Packages/UnitermKit/Sources/ScriptHost/ScriptControllers.swift:79-85`).
- `admit` still calls `ControllerSnapshot.create` on the path the command sent (`:162`). `create` opens, walks, reads,
  and copies the folder with blocking calls
  (`Packages/UnitermKit/Sources/ControllerPackage/ControllerSnapshot.swift:94-164`).
- The first report said the admission stays pending after the command is killed. That part was wrong. The connection's
  close clears it, and a late result removes its snapshot. The Observed, Cause, and Repro sections now say so.

The repro was not run. It needs a mount whose reads never return, and the Mac used had no FUSE file system installed.
No test pins the behavior. `admit` has no seam for a stalled read, and adding one would be the interim bound UTERM-057
rejected.

The estimate is large. The fix changes the ScriptWire controller begin, adds chunk messages shared with UTERM-034 M1,
and moves the package read into the command. UTERM-057 settles every design call, so none stays open here.
