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
| UTERM-015 M2: Finder and Dock | DONE | "Open files that Finder, the Dock, and Spotlight send" |
| UTERM-015 M3: File > Open | DONE | "Open files and folders from File > Open on Cmd-O" |

M2 added two milestones to UTERM-015 by amendment. M7, "Launch Services approvals", joins the queue row `UTERM-015
M4-M7`, which waits on UTERM-004 M6. M8, a check only the user can run, has its own queue row right after this one:
`UTERM-015 M8`, with no dependencies. It records the sender each Finder and Dock path reports, and checks Open With and
a Dock drop by hand.

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

### UTERM-015 M2: Finder and Dock

Commit: "Open files that Finder, the Dock, and Spotlight send".

Checks, final round:
- `make fmt-check`, `make lint`, and `make check` pass. The coordinator re-ran them on the final tree.
- `make test-package` ran 634 tests, with 4 skipped and 0 failures. The skips are older tests.
- `make test-app` passes. The first round ran 78 UI tests in about 10 minutes, including the new one.
- `proposals.py check` and `proposals.py freeze` report nothing.
- No uniterm crash report appeared during the manual sender runs. No app process was left running. The real
  `~/Library/Application Support/uniterm` folder matched its backup byte for byte afterwards.

Test cost:

| Test class | Tests | Wall time |
|---|---|---|
| `LaunchOpenCoordinatorTests` | 14 | 0.70 s |
| `SenderIdentityTests` | 9 | 0.10 s |
| `InfoPlistDriftTests` | 7 | 0.002 s |
| `OpenAuthorityTests` | 5 | 0.001 s |
| `LaunchServicesOpenUITests` | 1 | 3.1 s |

Sender measurements, from the debug build run directly on Darwin 25.6.0, with scratch layout and defaults
directories. Each open event carries two audit tokens: the sender, and an "actual sender" Launch Services adds.

| Path | Sender token | Actual-sender token |
|---|---|---|
| `open -a <app> <folder>`, app running | the `open` process, already exited, so unidentified | `com.apple.coreservices.uiagent` |
| `/usr/bin/open -a <app> <file> <folder>`, app running | `com.apple.open`, Apple-anchored, no team | `com.apple.coreservices.uiagent` |
| `open --env ... -a <app>`, app not running | already exited, so unidentified | `com.apple.coreservices.uiagent` |
| Finder, either case | not measured | not measured |

The Finder measurement was not taken. The run tried to drive Finder with `osascript`, and the permission check denied
the command. By the plan's fallback, the authority is built as settled. The Finder record moves to M8. Until M8 runs,
nobody knows whether a Finder open can be told apart from `open -a`. The proposal says that question reopens if they
cannot be.

The actual-sender token always names the Launch Services agent, never the program that ran `open`. So no attribute
names the originator, and the authority reads the sender token only.

The signing identifiers on this machine are `com.apple.finder`, `com.apple.dock`, `com.apple.Spotlight`,
`com.apple.osascript`, `com.apple.open`, and `com.apple.dt.xcode_select.tool-shim-public` for the `python3` shim. All
are platform binaries with no team.

Best guesses by the implementer:

- Approvals moved to M7, as the plan said. M2 still builds the sender identity from the PID and PID version. A test
  shows two PID versions are two identities.
- The Finder sender record became M8, a check only the user can run, by the plan's fallback. Open With and a Dock drop
  by hand also moved there from M2, because a check only the user can run cannot be left on a milestone marked done.
- The Apple opener list narrowed to Finder, the Dock, and Spotlight. No signed program was found for Quick Look or
  Recent Items. A narrower list fails safe: an unlisted opener is refused with a message. The Dock and Spotlight
  identifiers come from their binaries, but neither was measured as a sender.
- The authority reads only the sender token. The actual-sender token is logged and ignored. A hand-built Apple Event
  cannot carry these tokens, so the token read is proven live only.
- The sender is read from the current Apple Event inside the app delegate's open callback, where it was readable. The
  callback returns nothing, so AppKit's reply is the same for every outcome.
- Refusals coalesce to one message per 30 seconds in total, not per sender. A per-sender limit would let a loop of
  different senders post without bound.
- The batch confirmation reuses the close dialog's injectable confirmer. Eleven files ask, and ten do not. Its
  accessibility identifier still says `close-confirmation`.
- After a cold-launch replay in which every waiting file failed, one default window opens. A failed warm open with no
  window open opens nothing.
- The sender identity code sits in existing targets, so the Xcode project needed no edit.
- `Info.plist` is written by hand. It has one `public.folder` entry, at Alternate rank with the Viewer role, and no
  imported types. A drift test checks it against the catalog. The plist rank is always Alternate, whatever rank the
  applet declares, so a change to the declared rank is not drift.
- The UI test proves refusal only. An open sent from the test runner is refused with a message, and no pane opens. An
  accepted open needs Finder as the sender, so unit tests cover that path with a sender fixture.

Review findings and dispositions:

- M2 was marked done while it still owned a check only the user can run: Open With and a Dock drop by hand. Fixed. The
  check moved to M8 by amendment, and the Decision Log entry gives the prior wording.
- "Brought forward and unminimized" had no passing proof, because its test skipped without a window server. Fixed. The
  logic now takes a small window protocol, and two tests with a fake window run and pass.
- A Decision Log entry still said the ADR candidate waits on M2's sender record. Fixed to name M8. A risk bullet was
  rewrapped.
- The proposal said openers match on platform-binary requirements, but the code matches an Apple-anchored identifier.
  Fixed the wording. The coordinator ruled out adding `platform = 26`, because that number changes with each macOS
  release.
- M8 had no queue row. Fixed. Its row follows this one, and `proposals.py check` accepts the order.
- The drift test did not check each document type's role. Fixed. It now asserts the Viewer role.
- A string literal ran past 100 columns, and one doc block packed three ideas. Fixed.

ADR impact: no conflicts and no supersessions.

- PLAUSIBLE, dismissed: ADR-09 says identity alone grants no permission, and Finder, the Dock, and Spotlight open with
  no grant. The proposal settled that their opens are the user's own act, and the user kept that ruling at the review
  gate. The ADR candidate "which Launch Services senders count as the user's act" will settle the reading after M8.
- ADVISORY, fixed: ADR-08 asks any wait on the main thread to name its bound. The code-signing lookups run on the main
  thread in the open callback. A comment now names the bound. They are local checks of a signed binary and a live
  process, with no network and no user wait. The lookup cannot move, because the event is current only inside the
  callback, and an `open` sender exits within milliseconds.
- Three ADR candidates were dismissed. The sender rule already waits as a candidate in the Decision Log. "Authorize
  before touching a path" was declined earlier, as the Decision Log records. Cold-launch ordering becomes cross-cutting
  only when another entry point reuses it.

Left open:
- M8: the Finder sender record, at cold launch and while running, and Open With and a Dock drop by hand.
- Nobody has looked at the 11-file confirmation or a brought-forward window on screen. Tests prove both.

### UTERM-015 M3: File > Open

Commit: "Open files and folders from File > Open on Cmd-O".

Checks, final round:
- `make fmt-check`, `make lint`, and `make check` pass. The coordinator re-ran them on the final tree.
- `make test-package` ran 657 tests, with 4 skipped and 0 failures. The skips are older tests.
- `make test-app` ran 79 UI tests with 0 failures.
- `proposals.py check` reports only that the finished row moves to `history.md`, which the row's finish does.
- `proposals.py freeze` reports nothing.
- The coordinator found no uniterm crash report in `~/Library/Logs/DiagnosticReports` after the hand launch. The sandbox denied the implementer's own check.

Test cost: the new package tests run in under half a second together. `OpenPanelUITests` adds one UI test of about 22
seconds. One unit test uses a real 0.1-second timer. It ends a sheet late, to prove that placement waits for the sheet
to detach.

| Test class | Tests | Wall time |
|---|---|---|
| `FileOpenCommandsTests` | about 13 | about 0.5 s |
| `SourceOpeningTests` | 6 | under 0.05 s |
| `OpenCommandTests` | 3 | about 0.02 s |
| `BuiltInCommandsTests` | 1 | under 0.01 s |
| `OpenPanelUITests` | 1 | 22 s |

Visual check: a UI test screenshot showed the system Open panel as a sheet on the uniterm window, starting in the home
folder. The coordinator looked at it. That first capture covered the whole screen, including the user's other
windows. It was deleted, and the test now captures only the panel and keeps nothing on success. The user's own look
at File > Open and Open With is a check left to the user.

Best guesses by the implementer:

- The menu titles are "Open…" and "Open With…". The palette titles are "Open File or Folder" and "Open File or Folder
  With", so the palette never lists two "Open…" entries. A viewer's pane-local command is "Open…".
- Both commands are app-scoped, as New Window is, so they work with no window. The anchor is the key window's focused
  pane, or the pane the palette targets.
- A panel selection of more than 10 files asks first, through the same confirmation as Finder batches.
- A reported directory that is gone or relative falls back to home, never to AppKit's remembered folder.
- No production chooser is wired for run-time type ties. With the terminal as the only declaring applet, a tie cannot
  happen. A tie still refuses with a message.
- The pane-local Open helper lives in AppletKit, because applets cannot import WindowKit. The terminal does not adopt
  it, since it has no source to replace.
- Placement waits for an attached sheet to detach, for up to 25 checks 20 ms apart. It waits after the open panel,
  after the batch confirmation, and after the Open With chooser. AppKit's ordering could not be proven from its
  documentation.
- M3's controller half moved to M4 by amendment, as the plan's best guess 3 said.

Review findings and dispositions:

- CONFIRMED: the UI test kept a full-screen screenshot that showed the user's other windows. Fixed. It now captures the
  panel only, with `.deleteOnSuccess`. The earlier screenshot and the result bundles holding it were deleted.
- PLAUSIBLE, confirmed by trace: two Returns in the go-to-folder sheet could race. Fixed. The test waits for the sheet
  to close between them.
- The start-directory rule existed twice, once for the router and once for the pane-local Open. The two could disagree
  on a symlink to a folder. Fixed. One rule in AppletKit serves both, with a symlink test through the pane-local path.
- PLAUSIBLE, traced: placement could run while a sheet was still attached, and fall back to a new window. The trace
  found no documented ordering. Fixed with the bounded wait above. Its test fails with the wait disabled. Only the open
  panel is covered on screen. The confirmation and chooser sheets rely on the same wait and its unit test.
- The Cmd-O test covered only the terminal. Fixed. It now loops over every built-in applet's command set from the
  catalog. The app registers from that same list.
- No test showed the palette path anchoring to the pane the palette targets. Fixed.
- A doubled blank line in the proposal, and test fields placed in the wrong group. Fixed.

ADR impact: no conflicts and no supersessions.

- ADVISORY, recorded: with no window open, the open panel runs modally while it waits on the user. ADR-08 asks the main
  thread not to wait on the user. The modal loop still pumps events, and there is no other window to block. The M3 As
  built block says so.
- Three ADR candidates were dismissed. The pane-local source contract is a mechanism under the waiting "one route"
  candidate. "A path the user picked is not a grant" falls outside ADR-09, which governs programmatic effects. The
  panel's start-directory rule is already in the project's `CLAUDE.md`.

Left open:
- Nobody has watched the confirmation or the chooser sheet place a pane on screen.
- The user's hands-on look at File > Open and Open With.

## Status

In progress.
