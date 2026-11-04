# UTERM-015 M1-M3: Cross-applet file opening work-queue run

Started 2026-11-03. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-015 M1-M3`, from `spec/proposals/UTERM-015-cross-applet-file-opening.md`. UTERM-015 gives files one route
into an applet from outside its pane: a router that picks an applet by content type, Finder and Dock opens, and File >
Open. The specs live in the code repo, so every commit below is in `/Users/ripta/projects/uniterm`, on the
`agent/petunia` branch.

## TL;DR

In progress.

## Run state

The run's base is "Merge pull request #20 from galleon-bot/claude/uterm-015-file-opening", which is also the row's
base. The row has no dependencies, and no milestone carries a `Live after` line. Nothing was held or skipped.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-015 M1: The router | DONE | "Route files to applets by declared content type" |
| UTERM-015 M2: Finder and Dock | IN PROGRESS | |
| UTERM-015 M3: File > Open | QUEUED | |

## Local checks

Every milestone runs `make fmt-check`, `make lint`, `make check`, `make test-package`, and `make test-app`, then
`proposals.py check` and `proposals.py freeze`. `make test-app` needs a GUI session and Accessibility permission, so it
runs outside the agent sandbox.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. The batch confirmation threshold is 10 files. "Several files at once" asks for a fixed count and names no number.
   If the guess is wrong, only one constant changes.
2. M2's approval checks move to a new milestone, M7 "Launch Services approvals", by amendment. These are the session
   grant bound to the sender's PID and PID version, and the single prompt for a batch from a sender that needs
   approval. Both need UTERM-004 M6's approval flow, which does not exist yet. The queue row `UTERM-015 M4-M6` becomes
   `UTERM-015 M4-M7`, since M7 has the same dependency. If the guess is wrong, M7 folds back into M4-M6.
3. M3's controller half moves to M4 by amendment. That half says a controller gets no path or content from outside its
   scope when the user replaces the source of a pane it owns. M4 already carries the same check, and no controller,
   scope, or event channel exists yet. If the guess is wrong, M3 would build a scope type that M4 then owns.
4. M3 builds each viewer's pane-local Open command as a shared AppletKit helper, proven on a fixture applet. No viewer
   exists in code yet, as the proposal's risk "No viewer applet exists in code yet" says.
5. M1's check that a routed split never joins a group a controller owns runs against a fixture group, through an
   ownership seam. The re-run against UTERM-004's groups stays with UTERM-004 M4.
6. M2 records senders with Finder driven by `osascript`. If macOS denies Automation, the run records `open -a` only. It
   then splits the Finder recording into a user-check milestone by amendment. A hand click in Finder is a check left to
   the user, and is not a condition of M2 being done.
7. Saved "Open With" choices live in one defaults dictionary, keyed by exact type. The existing settings store supports
   only fixed key names, and a dictionary keeps unknown entries intact.

## Milestones

### UTERM-015 M1: The router

Commit: "Route files to applets by declared content type".

Checks, final round:
- `make fmt-check`, `make lint`, and `make check` pass. The coordinator re-ran them after the last `make fmt`.
- `make test-package` passes. The first round ran 589 tests, with 4 skipped and 0 failures.
- `make test-app` passes in about 10 minutes.
- `proposals.py check` and `proposals.py freeze` report nothing.

Test cost: the new test files run in under one second together.

| Test class | Tests | Wall time |
|---|---|---|
| `RoutedOpenerTests` | 14 | 0.82 s |
| `OpenWithTests` | 11 | 0.075 s |
| `FileRouterTests` | about 14 | about 0.01 s |
| `SymlinkTests` | 2 | 0.004 s |
| `CatalogAuditTests` | 4 | 0.001 s |
| `BuiltInAppletsTests` | 4 | 0.004 s |

Best guesses by the implementer:

- Content types reach the router through an injected type system. An unregistered `UTType(exportedAs:conformingTo:)`
  conforms to nothing, so fixture types need a table. Production wraps `UTType`. If a single system-wide type source is
  wanted instead, only that protocol changes.
- An applet type's declaration is data. The host attaches the factory, because the terminal's factory needs the
  Ghostty engine. A new `AppletCatalog` module lists the production declarations, so the router does not depend on
  Ghostty.
- Two unrelated declared types can both match one file. That run-time tie asks the user through the chooser and never
  picks. With no chooser, the open is refused with a message. This is amended into "How a file type maps to an
  applet".
- "Off the main thread" covers type resolution and file-system checks. AppKit placement stays on the main actor. M1's
  last check is amended to say so.
- Symlinks are followed. The kind and the content type come from the target, so a symlink to a FIFO is refused, and a
  dangling link counts as missing. The start directory keeps the path as the request named it, so a link to a folder
  starts its terminal at the link. This matches the shell's logical paths. If symlinks should be refused instead, one
  branch changes.
- When two panes tie for largest, the first pane in reading order wins. A wide pane splits side by side, and the other
  axis is the fallback.
- A batch is any request with more than one file. A batch always opens in a new window. A single file opens beside the
  anchor, or in a new window when the anchor is gone, a sheet is up, or there is no room.
- The pane-group seam has two calls. One asks whether a controller owns a pane's group. The other reports an ordinary
  split, and routed splits never make it, so a routed pane cannot join a group. The fixture group joins on ordinary
  splits, which shows the check can fail.
- Saved choices live under the defaults key `openWithChoices`, as a dictionary from exact type to applet type. Each
  entry decodes alone. Corrupt entries are ignored and kept. The writers are file-private to the chooser's model, so no
  script or controller can reach them. The compiler enforces this, so no test can show a failing call.
- The Open With alert has Open, Cancel, and Clear Saved Choice. "Always use" is disabled for dynamic types.
- The two new package products were added to the Xcode project by hand.

Review findings and dispositions:

- CONFIRMED: a symlink to a folder or a file was refused as `public.symlink`. The kind check followed the link, but
  the type lookup did not. Fixed, with a test against the real type system. That test failed before the fix.
- A test gap: the router tests used a fixture table that never returns `public.symlink`. Fixed by the same test.
- A doc comment on the largest-pane split named a sibling method instead of saying what it does. Fixed.
- A force unwrap in the largest-pane search. It could not crash, but it is gone.
- The amended off-main check needed its prior wording in the Decision Log. Fixed.

ADR impact: no ADR conflicts or supersessions. Three candidates were dismissed:
- Applet type declarations as data is a mechanism. Its invariant, one route into an applet's entry point, is already
  a waiting candidate in the Decision Log.
- The rule that a start directory flows only as an explicit input is already in the project's `CLAUDE.md`, which every
  session reads.
- A routed pane joining no controller's group waits on UTERM-004's groups, so it is not ready to record.

Left open:
- The re-run of the group check against UTERM-004's real groups waits for UTERM-004 M4.
- Nobody has looked at the Open With alert on screen yet. That check moves to M3, which puts it in a menu.

## Status

In progress.
