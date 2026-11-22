# The app opens a package folder the command names, with uniterm's privacy grants

**Status:** open
**Validation:** not confirmed; nothing was run. The path below is traced through the code. Whether uniterm holds a
grant for Documents, Desktop, or Downloads depends on the user's Mac.
**Found:** 2026-11-22, by the design critic reviewing UTERM-034

## Observed

`uniterm run <folder>` runs a controller package. The command never reads the package. It resolves the folder's path
and sends it to the app. The app opens that folder and copies the package with its own macOS privacy grants. A program
outside uniterm's process tree can name a folder it cannot read itself, directly or by swapping a parent folder for a
link after the command resolves it. The copy lands in a run folder under uniterm's caches, which the program can read
as the same user.

This is the package form of the bug UTERM-034 fixes for a declared script file. It is narrower. The app copies only the
files that `controller.json` lists, and each must match its listed digest. What leaks is a privacy prompt under
uniterm's name, whether a protected folder holds a package, and a copy of a real package the user keeps in a protected
place.

UTERM-015 "The path-reading power" says a program never borrows uniterm's macOS privacy grants.

## Cause

1. The command checks only that the path is a folder and resolves it
   (`Packages/UnitermKit/Sources/ScriptRuntime/ControllerCommands.swift:60-86`).
2. It sends the resolved path in the controller begin (`ControllerCommands.swift:84-86`).
3. The app opens it with `O_NOFOLLOW` on the last component only, then walks and copies it
   (`Packages/UnitermKit/Sources/ControllerPackage/ControllerSnapshot.swift:97`, `:275`).

## Repro

Not run. Expected repro on a Mac where uniterm holds a Documents grant and a test program, started outside uniterm,
does not:

1. Put a valid controller package at `~/Documents/pkg`.
2. From the test program, run `uniterm run ~/Documents/pkg`.
3. Expected: the run is refused before the app opens the folder. Actual, per the trace: the app opens and copies the
   package into a run folder under its caches.

## Fix

The fix needs a design call on who opens the package. The command can open the folder with the invoker's access and
pass its descriptor to the app, which walks it with the existing `openat` code. Or the command can read the listed files
and send them. UTERM-034 settles the declared-file case. Its choice is a precedent here, not a ruling.
