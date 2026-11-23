# UTERM-051: The Launch Reads the Layout Off the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-001, for the window and layout restore
- UTERM-004, for the routed opens that wait on the launch

## Summary

The launch stops reading and decoding the whole layout file on the main thread. That covers the file decode and each
applet's decode of its own payload. The design questions below settle how.

## Motivation

Bug `20261122-layout-launch-read-runs-on-main-thread` records the problem. `applicationDidFinishLaunching` calls
`LayoutPersistence.launch` synchronously. That calls `LayoutStore.beginLaunch`, which reads the file with
`Data(contentsOf:)` and decodes it with `LayoutCodec.decode`.

A pane has no tab cap. A layout with one browser pane of 50,000 tabs took about 1,146 ms to read and decode in a debug
build. The file was 1.9 MB. The wait grows with the tab count.

The file decode is not the whole cost. `LayoutCodec` decodes each pane's payload only as far as a `JSONValue` tree. The
browser's restoring init then calls `JSONValue.decoded(as:)` on its payload and on its undo state. That function
encodes the tree back to bytes and decodes them into the typed struct. It runs inside `windows.open(restoring:)` on
the main thread. Its cost has not been measured, but it handles the same records as the decode the bug timed.

No window exists during the wait. What freezes is the menu bar, the Dock, Cmd-Q, and the handling of open events. Moving
the work off the main thread does not shorten the time to the first window. It keeps the app responsive while the user
waits.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. These decodes have no bound.

The save side was fixed separately. Saving now encodes and writes off the main thread. Bug
`20261122-browser-describe-reencodes-tabs-on-main-thread` records a related cost that the fix left in place.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### How far the decode moves off the main thread

The complete option is listed first.

- Read the file, decode it, and decode each applet's typed payload off the main thread. Each applet type gains a
  nonisolated step that turns its saved description into a ready restore value. `BrowserDescription` is already
  `Sendable` and holds no AppKit types. The main thread then only builds objects. This changes the restore contract for
  every applet type.
- The same, but keep each payload's bytes in `AppletDescription` and decode them once into the typed struct. This
  drops the `JSONValue` round trip instead of moving it. It may be combined with the first option.
- Read and decode the file off the main thread only. The browser's typed decode stays on the main thread at restore.
  This leaves a decode of about the same size on the main thread.
- Cap the tabs per pane, and keep the read on the main thread. Addition: it brings in a product limit and a rule for
  stored layouts over the cap. It does not bound the file. Nothing caps panes or windows, URLs may be up to 32 KB, and
  each tab's undo state carries WebKit history of any size. A layout over the cap is either cut, which loses data, or
  kept, which leaves no bound.

### What the launch does with user commands that arrive during the read

Routed opens already wait. `LaunchOpenCoordinator` queues them until `launchFinished`, and `hasPendingOpen` reads that
queue at the moment the default window would open. That holds unchanged once `launchFinished` moves to the async
completion.

Other entry points run only after the launch today, because the launch is synchronous. During an async read they
reach `WindowSet` directly:

- Cmd-N opens a window.
- A Dock click calls `openIfNone`. No controllers exist yet, so it opens a window.
- File > Open calls the opener directly. It skips the coordinator queue and the pending count.

The restore then opens every saved window anyway, and `openDefault` checks only `hasPendingOpen`, not whether a window
is open. Either path leaves an extra window, and the saver then persists it. Scripts are not affected. They need an
existing controller.

- Queue these commands with the routed opens, and replay them in order after the launch. The default window counts
  them as pending.
- Let them run, and have the restore merge with what is open. The default window opens only when no window is open.
  The saved windows open beside any window the user opened.
- Refuse them until the launch finishes. A command that does nothing gives no feedback.

### What the app shows while the read runs

- No windows until the layout is ready. This is the plain behavior. The first window comes no later than today.
- A placeholder window, replaced when the layout arrives. Addition: it brings in a new UI component. If it is a real
  controller, a routed open can anchor to it and is lost when it is replaced.

## Risks

- **The off-main read ships while a decode of the same size stays in the restore** — likelihood: high if the
  read-only option is picked, impact: high.
  Mitigation: the first open question names it. Each option's checks include a release-build timing of the main
  thread's share of a 50,000-tab launch.
- **Quitting during the read** — likelihood: low, impact: medium.
  `applicationWillTerminate` releases the store on the main thread while `beginLaunch` may still run off it. The store
  allows only `save` across threads. A quit after the marker is written and before `finishLaunch` counts toward the
  crash bound.
  Mitigation: a milestone check settles what release does during a read, and documents the second cross-thread call.
- **The post-launch steps run before the layout is up** — likelihood: medium, impact: medium.
  `launchFinished`, the palette sync, `NSApp.activate`, the debug error post, and the questions hook follow `launch`
  in `applicationDidFinishLaunching`.
  Mitigation: a milestone check moves each one to the completion, and the `LayoutPersistence` tests move to the async
  API.

## Milestones

None yet. The open decisions come first.

## Decision Log

- 2026-11-22: Drafted from the bug report, after bug triage confirmed the bug by reading the code.
- 2026-11-22: Revised after design critique. The restore's typed decode was folded into the first question. It had
  been a separate question about the cost of building panes. The routed-open ordering question was replaced by the
  question about other entry points, because its candidates were all current behavior. The "default window plus saved
  layout" option was dropped from the display question. It grows the layout by one window per launch, and it opens a
  shell beside a routed pane.

## References

- ADR-08: UI responsiveness
- Bug `20261122-layout-launch-read-runs-on-main-thread`
- Bug `20261122-layout-save-runs-on-main-thread`, fixed
- Bug `20261122-browser-describe-reencodes-tabs-on-main-thread`
