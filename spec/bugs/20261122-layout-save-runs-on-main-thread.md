# The layout save encodes and writes every tab on the main thread

**Status:** fixed 2026-11-22
**Fixed:** 2026-11-22
**Estimate:** medium; two non-trivial design decisions. How quit waits for a pending write. Whether a tab cap replaces
the off-thread save. The user chose the off-thread save, with quit waiting for the write.
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

Expected: no main-thread stall. Actual: confirmed on 2026-11-22 with a throwaway package test. `LayoutStore.save` of
one browser pane holding 50,000 tabs wrote 1.9 MB and took about 102 ms in a debug build. All of it ran on the main
actor.

## Fix

Take the snapshot on the main thread, which is cheap, and encode and write off it, keeping one write in flight and the
newest snapshot pending. Read at launch off the main thread too. The design call is how quit waits for a pending write,
since quit must not lose the last layout.

## Fix note

Fixed on 2026-11-22 in `LayoutSaver.swift`, `LayoutStore.swift`, and `LayoutPersistence.swift`, with tests in
`LayoutSaverTests.swift` and `LayoutPersistenceTests.swift`.

The saver still takes its snapshot on the main actor. It now encodes and writes on a background queue. One write runs
at a time, and a snapshot taken during a write replaces the one waiting behind it. Quit calls `waitForWrites`, which
blocks until the write in flight and the one behind it finish. Only then is the lock let go. Turning saving off drops a
layout still waiting. Write failures still reach the status bar once per distinct failure.

The package suite and `LayoutUITests` pass, including quit and relaunch in the running app.

The regression test `testTheWriteRunsOffTheMainThread` failed before the fix, because the write ran on the main thread.
It passes after it.

The launch read stays on the main thread, so this fix is partial. Reading and decoding the same 50,000-tab file took
about 1,146 ms. That part is filed as `20261122-layout-launch-read-runs-on-main-thread`, since moving it is a design
call.
