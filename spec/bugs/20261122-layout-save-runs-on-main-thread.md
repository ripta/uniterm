# The layout save encodes and writes every tab on the main thread

**Status:** open
**Validation:** not confirmed; found by reading the code during the UTERM-049 review, not measured in the app.
**Found:** 2026-11-22, during the UTERM-049 review

## Observed

A window with many browser tabs makes every later layout change pay to encode and write all of them on the main thread.
A pane has no tab cap: the user's New Tab and, since UTERM-039, a controller can add any number. Each browser tab's
stored URL may be up to 32 KiB. A layout of tens of thousands of tabs would hitch the app after each debounced change.

## Cause

`LayoutSaver` is `@MainActor`. After its debounce it calls `try write(snapshot())`
(`Packages/UnitermKit/Sources/LayoutKit/LayoutSaver.swift`, about line 105). The write is `LayoutStore.save`, which
encodes and writes atomically on the same thread (`LayoutStore.swift`, about line 323). Launch reads the file with
`Data(contentsOf:)` (`LayoutStore.swift`, about line 191). ADR-08 allows only "a write of a known, small size" on the
main thread, and the layout's size grows with the tab count.

## Repro

Plant a layout with a browser pane of 50,000 `about:blank` tabs, launch, then resize the window and time the main
thread across the next save.

Expected: no main-thread stall. Actual: not yet measured.

## Fix

Take the snapshot on the main thread, which is cheap, and encode and write off it, keeping one write in flight and the
newest snapshot pending. Read at launch off the main thread too. The design call is how quit waits for a pending write,
since quit must not lose the last layout.
