# A viewer stats a picked or dropped file on the main thread

**Status:** open
**Validation:** not confirmed; found by reading the code during the UTERM-050 review. The hang needs a mount that stops
answering.

## Observed

A user drops a file from a network share onto a data, map, image, or text viewer, or picks one in the pane's own Open.
When the share has stopped answering, the app may freeze until the mount times out.

## Cause

- `SourceStartDirectory.of(_:)` (`Packages/UnitermKit/Sources/AppletKit/SourceStartDirectory.swift`, about lines 15-20)
  calls `stat` on the file to learn whether it is a folder.
- It runs on the main actor from `SourceOpening.open` (`AppletKit/SourceReplacing.swift`) and from each viewer's drop
  handler: `DataViewerApplet.swift` (about line 326), `MapViewerApplet.swift` (about line 593),
  `ImageViewerApplet.swift` (about line 494), and `TextViewerApplet.swift` (about line 1064).
- A drop can come from any app, so its mount has not answered recently. The open panel's listing is no guarantee
  either, since a mount can stop answering after the listing.
- The router already classifies the same kind of path off the main thread (`FileRouting/FileRouter.swift`, about
  lines 46-57). ADR-08 asks for main-thread work whose duration uniterm bounds.

## Repro

Mount a network share, then make the server unreachable so the mount hangs. Drag a file from the share's Finder window
onto a text viewer pane. Expected: the app stays responsive. Suspected actual: the app stops responding until the mount
times out.

## Fix

Classify the path off the main thread, as the router does, then replace the source when the answer arrives. The Open
flow is already `async`. The drop handlers are synchronous, so each needs a request and a later reply, and must drop
the reply when the pane closed meanwhile. No design call is known. UTERM-050 covers the current-directory checks next
to this one, and leaves this path out because it is not a current directory.
