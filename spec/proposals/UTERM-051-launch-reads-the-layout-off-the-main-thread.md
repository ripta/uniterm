# UTERM-051: The Launch Reads the Layout Off the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-001, for the window and layout restore
- UTERM-004, for the routed opens that wait on the launch

## Summary

The launch stops reading and decoding the whole layout file on the main thread. The design questions below settle how.

## Motivation

Bug `20261122-layout-launch-read-runs-on-main-thread` records the problem. `LayoutPersistence.launch` calls
`LayoutStore.beginLaunch` on the main actor. That reads the file with `Data(contentsOf:)` and decodes it with
`LayoutCodec.decode`.

A pane has no tab cap. A layout with one browser pane of 50,000 tabs took about 1,146 ms to read and decode in a debug
build. The file was 1.9 MB. The wait grows with the tab count.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. This read has no bound.

The save side was fixed separately. Saving the same layout now encodes and writes off the main thread.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Whether the launch gets faster or the layout gets smaller

- Read and decode off the main thread. `launch()` becomes asynchronous. Nothing a user can do changes.
- Cap the tabs per pane. The read stays on the main thread, and its size gets a bound. This changes what users can do,
  and it needs a rule for a saved layout that already exceeds the cap.
- Both. The cap is a separate decision, and this option names it as a scope addition.

### What the app shows while the read runs

Applies only when the read moves off the main thread.

- No windows until the layout is ready. The launch looks slow but stays simple.
- A placeholder window, replaced when the layout arrives.
- A default window opens at once, and the saved layout opens beside it when it arrives. This puts two sets of windows in
  play.

### How routed opens and the launch marker order against an async launch

The app delegate, the opens routed from other processes, and the launch marker depend on `launch()` being synchronous.
`hasPendingOpen` is asked while the launch runs, and `beginLaunch` writes the marker after the read.

- Opens that arrive during the read wait until the launch finishes, then run in arrival order.
- Opens that arrive during the read count as pending, so the launch skips its default window, as it does today.
- The marker moves with the read. It is written once the read ends, before any window opens.

### Whether building the restored panes needs the same treatment

Restoring a pane with 50,000 tabs creates every tab on the main thread. This has not been measured. The decode is the
part the bug measured. The candidates are to leave the restore as it is, or to measure it first and open its own bug if
it is slow.

## Risks

- **A launch that outlives the app delegate's startup hook** — likelihood: medium, impact: high.
  Mitigation: the ordering decision above names what runs before the read ends.

## Milestones

None yet. The open decisions come first.

## Decision Log

- 2026-11-22: Drafted from the bug report, after bug triage found the bug still reproduces by code reading.

## References

- ADR-08: UI responsiveness
- Bug `20261122-layout-launch-read-runs-on-main-thread`
- Bug `20261122-layout-save-runs-on-main-thread`, fixed
