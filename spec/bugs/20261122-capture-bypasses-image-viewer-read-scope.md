# A program's pane capture can show an image the program may not read

**Status:** open
**Found:** 2026-11-22, during the UTERM-055 critique
**Validation:** confirmed against UTERM-054's text and the image viewer's contract; capture is not built yet
**Estimate:** large; non-trivial design decisions. The fix is a rule in an accepted, unbuilt proposal, not code. Decisions: (1) whether capture refuses for files the caller may not read, or the capture power's review text states that it reads whatever a pane shows and the image viewer's contract narrows to paths and listings; (2) which applets the rule covers (image, text, data, and the map viewer's file layer); (3) for the map viewer, whether a refusal applies or the file layer is left out of the image. Each option is equally correct and changes behavior a program can observe, so none is trivial. No code to touch yet; the change lands in UTERM-054 and UTERM-055 text first.

## Observed

The image viewer promises that nothing from a file the caller may not read leaves the pane. Its replies and events carry
an image's path only when the caller's scope holds both the source and the image's real path. An exec driver holds no
path-reading power, so its events always withhold the path.

UTERM-054 lets a program capture a pane in its tab scope, under the pane capture power. It has no read-scope refusal. A
script or driver whose source pane is an image viewer showing a user-opened image can capture the pane and get the
image's pixels, which the viewer's own contract withholds from it.

The map viewer has the same gap. Its `pin-selected` event gives a pin from the user's file only its source, and no
ID, coordinate, or other value from the file. A capture of a map pane that shows a user-opened GeoJSON file shows
those pins at their positions, and the pin list shows their names.

## Cause

- The contract: `Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Remote.swift:13-16`
- The map viewer's file-layer contract: the `pin-selected` schema and `pinSelected` in
  `Packages/UnitermKit/Sources/MapViewerApplet/MapViewerApplet+Remote.swift`
- UTERM-054, "Which panes a program may capture" and "Scripts and controllers capture too", which check the tab scope
  and the capture power, and no file read scope

## Repro

By trace, once UTERM-054 M1 and M5 are built. The user opens a private image in an image viewer pane, then runs a
script there that holds the capture power and no path-read power. Expected under the viewer's contract: the image does
not leave the pane. Under UTERM-054 as written: the capture returns the image.

## Fix

This needs a design call in UTERM-054:

- The image viewer's capture refuses with a named reason when the caller's scope does not hold the image's path, as
  its replies withhold the path.
- The capture power's review text states that a capture reads whatever a pane shows, including files the program may
  not read, and the image viewer's contract narrows to paths and listings.
- The text viewer and the data viewer show files too. Whichever rule wins, check them under it.
- The map viewer's file layer needs the same rule. A refusal there could instead leave the file layer out of the image.
- UTERM-055 gives exec drivers a caller with no read scope, so the resolution applies to drivers as written. UTERM-055
  M1 waits for this bug's resolution. UTERM-054 does not name this bug yet.
