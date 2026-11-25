# An applet's current directory checks the file system on the main thread

**Status:** proposed, see [UTERM-050](../proposals/UTERM-050-current-directory-never-blocks-the-main-thread.md)
**Triaged:** 2026-11-22 (hang not reproduced, it needs a mount that stops answering; code still matches; fix needs a design call)
**Validation:** not confirmed; found by reading the code during the UTERM-048 review, not reproduced in the app.
**Found:** 2026-11-22, during the UTERM-048 review

## Observed

A shell can report through OSC 7 a directory on a dead network mount, such as a hung SMB share. A viewer can also show
a file whose folder sits on such a mount. Then a script calling `list-panes` on that pane, or the user opening a new
pane or tab beside it, may freeze the app for as long as the mount hangs.

## Cause

- `TerminalApplet.currentDirectory` (`Packages/UnitermKit/Sources/TerminalApplet/TerminalApplet.swift`, about lines
  296-297) calls `RestoreDirectory.local(_:exists:)` with `RestoreDirectory.isLocalDirectory`. That calls
  `FileManager.fileExists(atPath:isDirectory:)` on the reported path (`RestoreDirectory.swift`, about lines 30-33).
- The four viewers check their open file's folder the same way inside `currentDirectory`, through `isDirectory`:
  `DataViewerApplet.swift` (about line 111), `MapViewerApplet.swift` (about line 214), `TextViewerApplet.swift` (about
  line 208), and `ImageViewerApplet.swift` (about line 247).
- Applets run on the main actor, and every caller reads the property there:
  - `WindowScripting` for `list-panes` (about line 142) and for opening a tab (about line 255)
  - `MainWindowController` for a new pane (about line 590)
  - the terminal's own new tab, reopened tab, and restore from a description (`TerminalApplet.swift`, about lines 207,
    501, and 620)
  - the open panel's starting folder (`AppletKit/SourceReplacing.swift`, about line 71)
- `TerminalApplet.swift` says a file-system check on a program-chosen path "on a dead network mount ... never returns"
  (about lines 46-49). It runs link checks off the main thread for that reason. ADR-08 asks for main-thread work whose
  duration uniterm bounds.

## Repro

Mount a network share, `cd` into it in a uniterm terminal, then make the server unreachable so the mount hangs. Run
`uniterm` `list-panes` from another pane. Expected: the call returns, with or without a directory. Suspected actual:
the app stops responding until the mount times out.

## Fix

The fix is a rule for the applet contract's `currentDirectory`: it does no blocking file-system work on the main
thread, in any applet. The rule belongs in the member's doc comment (`AppletKit/Applet.swift`, about lines 242-245).
How each applet meets it needs a design call. The options:

- `currentDirectory` returns the path with no existence check. Each consumer that starts a process or opens a panel in
  it checks existence off the main thread, or lets the start fail and falls back. `list-panes` then reports the path as
  the applet holds it.
- Each applet keeps a cached existence verdict, refreshed off the main thread when its path changes.
  `currentDirectory` reads the cache, and a path not yet checked reads as unknown.

UTERM-048's Pane Inspector polls `currentDirectory` once a second, so its M2 waits on this fix.

## Investigation notes

Triage run on 2026-11-22.

- `TerminalApplet.currentDirectory` still calls `RestoreDirectory.local` with `RestoreDirectory.isLocalDirectory`, which
  calls `FileManager.fileExists`. The report's other citations were not rechecked line by line.
- No test covers the property's main-thread behavior. The terminal takes an injectable existence check, so a test can
  block it and read the property on the main actor.
- The hang itself was not reproduced. No mount that stops answering was available.
- The fix has two options and no clear winner, so it went to UTERM-050.
