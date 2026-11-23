# A viewer stats a picked or dropped file on the main thread

**Status:** open
**Estimate:** medium; one non-trivial design decision. Four drop handlers and the shared Open path change, and ten tests that
call `handleDrop` and expect the swap to have happened on return must wait for it. The decision is what a drop answers
before the stat returns. `handleDrop` returns `Bool` today, so a failed open rejects the drop. With an off-thread
stat the handler must answer `true` first. A failed open then shows only the status-bar alert, with no rejected-drop
animation. Whether that change is acceptable, or a drop shows a pending state, is a judgment call. Two smaller points
look trivial: a later drop on the same pane wins over an earlier pending one, and a closed pane drops the reply, as the
router's callers do. No open proposal owns this. The accepted proposal for current directories leaves this path out on
purpose. Triage traced the code and did not reproduce it, since a hung mount is not cheap to build.
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
