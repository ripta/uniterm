# The launch reads and decodes the whole layout file on the main thread

**Status:** proposed, see [UTERM-051](../proposals/UTERM-051-launch-reads-the-layout-off-the-main-thread.md)
**Found:** 2026-11-22, while fixing `20261122-layout-save-runs-on-main-thread`
**Estimate:** large; non-trivial design decisions: (1) async `launch()` versus a per-pane tab cap, (2) what the app shows while the read runs, (3) how routed opens and the launch marker order against an async launch.

## Observed

A layout with one browser pane of 50,000 tabs takes about 1,146 ms to read and decode at launch, in a debug build. All
of it runs on the main thread. A pane has no tab cap, so the file's size, and this wait, grow with the tab count.

## Cause

`LayoutPersistence.launch` calls `LayoutStore.beginLaunch` on the main actor. That reads the file with
`Data(contentsOf:)` and decodes it with `LayoutCodec.decode` (`LayoutStore.swift`, `readLayout`). ADR-08 allows only
local work whose duration uniterm bounds on the main thread, and this has no bound.

The decode dominates. Saving the same layout took about 102 ms to encode and write.

## Repro

A throwaway package test saved the 50,000-tab layout with `LayoutStore.save`, then timed a second store's
`beginLaunch`. The file was 1.9 MB.

## Fix

Not settled. Moving the read off the main thread changes `launch()` from synchronous to asynchronous. The app
delegate, the routed opens that wait on the launch, and the launch marker all depend on that shape. What the app shows
while the read runs is a design call. A cap on tabs per pane is another option, which changes what users can do.
