# Undo reopen of a closed pane decodes its description on the main thread

**Status:** open
**Triaged:** 2026-11-22 (still reproduces by trace; design question opened in UTERM-051)
**Estimate:** large; one non-trivial design decision. Reopen becomes asynchronous, so the window must say what it shows and accepts while the reopen is pending.
**Found:** 2026-11-22, during the UTERM-051 review
**Validation:** mechanism confirmed by reading the code; cost measured only through the launch restore

## Observed

Undoing the close of a browser pane with many tabs holds the main thread while the pane decodes and rebuilds. The cost
grows with the pane's tab count. At 10,000 tabs, the same restoring init takes about 1.8 s at launch in a debug build.
Most of that is the tab bar's views, and about 32 ms is the decode.

## Cause

`MainWindowController` reopens a closed pane through `PaneRestoration.applet(for:restorer:)`
(`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:1190`). That calls the applet's restoring init
synchronously on the main thread. The init decodes the payload and the undo state with `JSONValue.decoded(as:)`, then
builds the applet.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound.

## Repro

Not run as an undo. The launch restore measurement in UTERM-051's Decision Log times the same init.

## Fix

Not settled. UTERM-051 gives each applet type an off-main step and a main-thread build, and undo reopen runs both on
the main thread. Running the off-main step off the main thread for undo too makes reopen asynchronous. The design call
is what the window shows and accepts while the reopen is pending. The view-building part belongs to bug
`20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`.

UTERM-051 now carries the question as an open scope addition, "Whether undo reopen of a closed pane also leaves the main
thread". Triage on 2026-11-22 confirmed the call path at `reopenPane` is unchanged. It was not timed as an undo.
