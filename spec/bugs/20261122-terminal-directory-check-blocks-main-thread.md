# A terminal's current directory checks a program-chosen path on the main thread

**Status:** open
**Validation:** not confirmed; found by reading the code during the UTERM-048 review, not reproduced in the app.
**Found:** 2026-11-22, during the UTERM-048 review

## Observed

A shell can report through OSC 7 a directory on a dead network mount, such as a hung SMB share. Then a script calling
`list-panes` on that pane, or the user opening a new pane or tab beside it, may freeze the app for as long as the mount
hangs.

## Cause

- `TerminalApplet.currentDirectory` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`, about lines
  296-297) calls `RestoreDirectory.local(_:exists:)` with `RestoreDirectory.isLocalDirectory`. That calls
  `FileManager.fileExists(atPath:isDirectory:)` on the reported path (`RestoreDirectory.swift`, about lines 30-33).
- The applet runs on the main actor. Its callers read the property there: `WindowScripting` for `list-panes` (about
  line 142) and for opening a tab (about line 255), and `MainWindowController` for a new pane (about line 590).
- The same file says a file-system check on a program-chosen path "on a dead network mount ... never returns" (about
  lines 46-49). It runs link checks off the main thread for that reason. ADR-08 asks for main-thread work whose
  duration uniterm bounds.

## Repro

Mount a network share, `cd` into it in a uniterm terminal, then make the server unreachable so the mount hangs. Run
`uniterm` `list-panes` from another pane. Expected: the call returns, with or without a directory. Suspected actual:
the app stops responding until the mount times out.

## Fix

This needs a design call. The options:

- `currentDirectory` returns the reported absolute path with no existence check. Each consumer that starts a process in
  it checks existence off the main thread, or lets the start fail and falls back. `list-panes` then reports the path as
  reported.
- The terminal keeps a cached existence verdict, refreshed off the main thread when OSC 7 reports a new path.
  `currentDirectory` reads the cache, and a path not yet checked reads as unknown.
