# The UI tests' open-panel paste replaces the real clipboard and restores only its text

**Status:** open
**Validation:** found by reading the code, not reproduced. `clearContents()` drops every item on the pasteboard, and
the helper puts back only a plain string.
**Found:** 2026-11-21, while speeding up UI test waits

## Observed

`UnitermUITestCase.paste(_:in:)` (`UITests/UnitermUITestCase.swift`, about line 388) types a path into the open
panel's go-to field through `NSPasteboard.general`. It saves the pasteboard's string, clears the pasteboard, writes
the path, sends Cmd-V, and writes the saved string back.

Three things go wrong on the developer's machine:

- Whatever else the clipboard held is lost. An image, a copied file, or rich text does not come back. Only plain text
  does.
- A clipboard history tool records each test path.
- A test that stops between the write and the restore leaves the path on the clipboard, and the saved text is gone.

The clipboard may hold secrets, so tests are meant to leave it alone. The terminal tests already use a private
pasteboard for the same reason.

## Cause

The go-to field belongs to the system's open panel, so it only takes a paste from the general pasteboard. The helper
pastes because typing the path let the field autocomplete each component into a sibling folder's name. See the fixed
`DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile` entry in `spec/flaky-tests.md`.

## Fix

This needs a design call. Candidates:

- Keep the paste, but save and restore every pasteboard item with all its types. This keeps the user's clipboard
  whole after a normal run. A history tool still records the path, and a stopped test still loses the clipboard.
- Type the path again, through a path that cannot autocomplete. A scratch folder whose components share no prefix
  with their siblings would stop the rewrite.
- Leave the open panel out of most tests. Open files through Launch Services or the `uniterm` command, and keep one
  test that drives the panel. That test could still skip the clipboard by typing a path built as above.

## Workarounds

Copy nothing worth keeping before a local UI test run.
