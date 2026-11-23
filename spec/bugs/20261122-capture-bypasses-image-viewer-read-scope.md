# A program's pane capture can show an image the program may not read

**Status:** open
**Found:** 2026-11-22, during the UTERM-055 critique
**Validation:** confirmed against UTERM-054's text and the image viewer's contract; capture is not built yet

## Observed

The image viewer promises that nothing from a file the caller may not read leaves the pane. Its replies and events carry
an image's path only when the caller's scope holds both the source and the image's real path. An exec driver holds no
path-reading power, so its events always withhold the path.

UTERM-054 lets a program capture a pane in its tab scope, under the pane capture power. It has no read-scope refusal. A
script or driver whose source pane is an image viewer showing a user-opened image can capture the pane and get the
image's pixels, which the viewer's own contract withholds from it.

## Cause

- The contract: `Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerApplet+Remote.swift:13-16`
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
