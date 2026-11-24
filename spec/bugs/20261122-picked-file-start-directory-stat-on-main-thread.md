# A viewer stats a picked or dropped file on the main thread

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23
**Estimate:** medium; no open design decisions. Four drop handlers and the shared Open path change. An earlier estimate
named one decision: what a drop answers before the stat returns, on the premise that a failed open rejects the drop.
That premise was wrong. No viewer's `replaceSource` throws: each starts an async open and reports a failure in the
status bar. So a drop's `Bool` reflects only the one-file check, and answering it before the stat changes nothing a
user sees.

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

## Fix note

Triaged and fixed on 2026-11-23. The trace held: `SourceStartDirectory.of(_:)` ran `stat` on the main actor from the
four drop handlers and from `SourceOpening.open`. The hang itself was not reproduced, since it needs a mount that stops
answering.

A new `SourceSwap` in `AppletKit/SourceSwap.swift` learns the start directory through
`SourceStartDirectory.resolving`, which is `@concurrent`, and swaps the source when it answers. A later drop or Open
on the same pane supersedes one still waiting, and a closing pane cancels it. `SourceReplacing` gains a `sourceSwap`
requirement and `replaceSource(withChosen:)`, which the Data, Map, Image, and Text drop handlers and the pane-local
Open now call. Each viewer's `close()` cancels the swap.

The regression test is `testADropWaitsForItsStatOffTheMainThreadAndTheLaterDropWins` in
`Tests/TextViewerAppletTests/TextViewerAppletTests.swift`. It holds the first drop's stat, drops a second file, then
releases the first. Before the fix, the first drop swapped the source at once, since its stat ran inline. Two tests that
expected the swap on return now await the pending swap. The test cannot prove the default classifier leaves the main
thread. `@concurrent` carries that, as it does for the router's classification.
