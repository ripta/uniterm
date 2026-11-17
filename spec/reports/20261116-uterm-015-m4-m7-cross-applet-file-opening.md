# UTERM-015 M4-M7: Cross-applet file opening work-queue run

Started 2026-11-16. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-015 M4-M7`, from `spec/proposals/UTERM-015-cross-applet-file-opening.md`. UTERM-015 gives files one route
into an applet from outside its pane. M1 to M3 and M8 built the router, Finder and Dock opens, and File > Open, and
recorded Finder's sender. This row adds the path-reading power a controller needs (M4), the `uniterm open` command
(M5), Cmd-hover and Cmd-click in the terminal (M6), and approvals for Launch Services senders that are not Apple's
openers (M7). The specs live in the code repo, so every commit below is in this repo, on the `agent/petunia` branch.

## TL;DR

In progress.

## Run state

The run's base and the row's base are the commit "Write line breaks and tabs as two-byte JSON escapes in the script
helper". The row's gate, UTERM-004 M6, is met. Every milestone dependency is met: UTERM-003 M3 and UTERM-004 M1, M3,
and M6 are DONE, and M5's dependency on M4 runs in this run. No milestone carries a `Live after` line. Nothing was
held or skipped.

Other sessions commit to `agent/petunia` during this run. The row's commit range therefore holds commits that are not
this run's, such as "File the unclaimed Command key that reaches terminal programs". Reviews cover only this run's
commits, which are named by subject below.

The plan's step 0 was a rebase onto `upstream/main`. It was skipped. The checkout holds uncommitted edits from other
sessions to `spec/proposals/UTERM-025-presentation-controller.md` and
`spec/proposals/UTERM-031-controller-keys-in-text-panes.md`. The session editing UTERM-031 said it is mid-review and
asked that the run stay on the current base. The run never stashes another session's edits, so it ran on the current
base. Whether to rebase `agent/petunia` is left to the user.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-015 M4: The path-reading power | DONE | "Let a controller read paths inside an approved directory scope" |
| UTERM-015 M5: `uniterm open` | DONE | "Open files from a terminal with `uniterm open`" |
| UTERM-015 M6: Terminal clicks | DONE | "Open the path a terminal shows on Command-click" |
| UTERM-015 M7: Launch Services approvals | DONE | "Ask before opening files that other apps send" |

## Local checks

Every milestone runs `make fmt-check`, `make lint`, `make check`, and `caffeinate -dimsu make test-package`, plus a
`build-for-testing` of the UI tests. The coordinator runs the UI test classes each milestone touches through `cg_run`,
and the full `make test-app` at the row and final reviews. M4 and M5 also run `make fuzz`. M5 also runs
`make test-helper-sandbox`. M6 also runs `make ghostty` and `make ghostty-offline-check`. Each milestone also runs
`proposals.py check` and `proposals.py freeze`.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. M4 has no production consumer, since no controller command reads a path today. M4 builds the host service, a path
   argument type, and redaction, and proves them on fixture applets. Rests on UTERM-015 Risks, "No viewer applet exists
   in code yet". If wrong, a real viewer command lands with M4.
2. The path-reading permission joins the meanings table with no descriptor format bump. An older build already refuses
   an unknown kind, and it refuses a policy file holding one as newer. Rests on ADR-09, "Unsupported meanings authorize
   nothing". If wrong, the descriptor format goes to 3.
3. The host resolves a path argument through the scoped open at the effect boundary, and the applet receives an opened
   descriptor. Rests on ADR-09, "Authorization is checked at the effect boundary".
4. Redaction covers panes with a user file as their source, including the text viewer's `find` results. Rests on "The
   path-reading power", bullet 4.
5. Ghostty patch 003 reports an OSC 7 that names another host, and stops libghostty's `access()` on clicked relative
   paths. Rests on "Who may open by terminal click" and its Risks entry.
6. The remote marker covers the whole pane, set from kqueue tracking of the session's descendants and from the patched
   OSC 7. Rests on M6's decision text, "Where the pinned libghostty cannot mark rows". Row marks were weighed and
   rejected for maintainability: a deep patch to Ghostty's page storage, carried on every pin bump. Left undone: one
   `ssh`, even a `git fetch` over ssh, turns off clicks in that pane for good.
7. A `~/` path in terminal output counts as relative and is refused. Rests on "Start directory and current directory".
8. The hover display is an overlay at the bottom-left of the terminal, as in Ghostty's own app. Rests on the project
   `CLAUDE.md` "UI Feedback".
9. A click verifies the real path, then routes that path. The viewer reopens it by path, so a same-user rename in
   between is a residual, accepted under ADR-09's "no isolation from the user's own processes".
10. `uniterm open` bumps `ScriptProtocol.version` from 12 to 13.
11. A Launch Services approval waiting at cold launch lets the default window open, so the pending indicator has a
    window.
12. M5 and M7 share one new once-only flag on pending-indicator rows.
13. Redaction does not cover content a controller sent itself with `send`. `reload` on an out-of-scope source runs, and
    its reply is uniform.
14. `uniterm open` always replies uniformly, since the command never holds the path-reading power. Failure detail goes
    to the app's status message.
15. In M7, every Apple-anchored sender that is not an Apple opener gets Allow once only, as does an unidentified sender.
    Third-party signed apps get once or session. No unmeasured helper identifier is listed.
16. Panes M5 and M7 open take no focus, per ADR-12. Path-reading commands with an effect reply at once, per ADR-11.

The plan also named one hidden state flow, per the project `CLAUDE.md` "Applet Attributes". libghostty resolves a
clicked relative path against its own tracked directory and checks it on disk. UTERM-015 already settles that a clicked
relative path is refused, so patch 003 removes the library's resolution. Plan approval confirmed it.

## Milestones

### UTERM-015 M4: The path-reading power

The implementer built a `path-read` permission (format 2, version 1, a `directories` list) and a protected-location
list in `Packages/UnitermKit/Sources/SourceAccess/ProtectedLocations.swift`. It also built a scoped open in
`ScopedOpen.swift`, and a path argument type in the applet command schema that hands the applet opened descriptors. A
fixture applet, `Tests/AppletFixtures/PathsFixture.swift`, proves it. Redaction covers pane-list titles, tab titles,
and directories, and the text viewer's wait replies.

First-pass checks: `make fmt-check`, `make lint`, `make check`, `caffeinate -dimsu make test-package` (2719 tests),
`caffeinate -dimsu make fuzz` (about 346 s), and a `build-for-testing` all passed. `proposals.py check` reported no
finding on UTERM-015. Its two findings are index drift on UTERM-024 and UTERM-025, which belong to other sessions.
`proposals.py freeze` returned no hunks.

The coordinator's first two runs of the touched UI classes did not start. Both failed at Automation Mode
authentication with "Authentication canceled. Canceled by user." (`cg_run` IDs 8HM8MS and P5S1AG, 2026-11-16 22:27).
No UI test ran in either.

New test classes, timed alone in the package suite: `ScopedOpenTests` 13 tests in about 0.5 s, `ReadScopeTests` 8 in
under 0.05 s, `ControlDispatcherPathTests` 8 in 0.07 s, `PathReadWindowTests` 3 in 0.23 s.

Implementer best guesses and deviations, each in the proposal's Decision Log:

1. The scoped open runs off the main thread in `WindowScripting.sendCommand`, before the command is queued. Delivery
   asks for the access again and checks each descriptor's real path against the current scope. The plan put the walk
   inside the authority closure. ADR-08 rules that out.
2. Allow once does not let a controller read paths. Only Allow for This Run or a remembered approval does. "How the
   path-reading power is granted" was amended in place. If wrong, Allow once needs per-read prompts, which the proposal
   rejects for slideshows.
3. Two approved read scopes act as their union.
4. `/net` and `/home` joined the protected list as network mount points.
5. Redaction applies to every caller of the pane list, ordinary scripts included, since an ordinary script holds no
   scope. The plan scoped it to controllers. If wrong, scripts without the power see user files' titles again.
6. Exec drivers bring no opens, so a command that names a path is refused for them.
7. In Janet lint, a declared `path-read` counts as used when the file sends any command.

Review findings and their dispositions:

- Protected-name matching used Swift `lowercased()`, not APFS's Unicode case fold. `~/Deſktop` reached `fstatat` on
  Desktop before the final check refused it. CONFIRMED. Sent to fix.
- `OpenedPath.memberNames` returned an empty list on a second call, because a `dup` shares the directory offset.
  CONFIRMED. Sent to fix.
- The review panel offered Allow once for `path-read` without saying that it grants no reads. It also gave the same
  refusal as an out-of-scope path. A plan gap from deviation 2. Sent to fix.
- The panel named protected places by the written scope path only. A scope link into Documents went unnamed, which
  misses M4's last check. Sent to fix.
- Redaction compared paths exactly, which could under-hide another-case spelling of a protected place. PLAUSIBLE.
  Sent to trace.
- The text viewer's wait copied the read access at delivery while its comment said it is asked at reply time.
  PLAUSIBLE. Sent to trace.
- ADR-08, from adr-impact: the delivery re-check ran `realpath` and `pathconf` on the main thread. The public
  `memberNames` and `openMember` would block a main-thread caller. PLAUSIBLE. Sent to trace.
- Deviations 2 and 5 are recorded here for the user. They are kept as amended.

Fix round outcome:

- Case folding: fixed. The regression tests with U+017F and U+212A failed first, since `Deſktop` reached a lookup.
  Protected places now match by Unicode case fold on every volume. The fold is the standard library's scalar case
  mapping.
- `memberNames`: fixed, with a rewind after `fdopendir`. A two-call test failed first.
- Allow once: the review panel now says reads need Allow for This Run or a trust choice. A run allowed once gets its own
  refusal text. Every out-of-scope refusal stays one text.
- Resolved scope: links in scope directories are resolved off the main thread, when a review is queued and when the
  Controllers window first shows a directory. A link into a protected place is now named.
- Redaction under-hiding: the trace confirmed it, since a routed or typed path can carry another-case spelling. The
  case-fold fix covers it.
- Wait access copy: the trace did not confirm it. A run's standing power only grows, and revoking it ends the run,
  which fails pending waits. The comments were corrected. Diagnosis: not a bug, unresolved by test.
- ADR-08: the trace confirmed it. Opened paths keep the roots resolved off the main thread, so delivery re-checks with
  string work and one `F_GETPATH` on an open descriptor. A scope that changed while a command waited refuses it.
  `memberNames` and `openMember` are now async and run off the main thread.

Second-round checks: `make fmt-check`, `make lint`, `make check`, `caffeinate -dimsu make test-package`,
`caffeinate -dimsu make fuzz`, and `build-for-testing` all passed. `proposals.py freeze` returned no hunks.

UI tests: the coordinator ran `ScriptRunUITests`, `ReplUITests`, `PresentationUITests`, `TextViewerUITests`,
`ControllerRunUITests`, and `ControllerConsentUITests` with `-only-testing` through `cg_run` (ID NBAMK5,
2026-11-16 23:27). All 33 tests passed in 443 s. The two earlier attempts had been cancelled at the Touch ID prompt,
because the user needed the screen. `~/Library/Logs/DiagnosticReports` gained no report during the run. The latest
reports were `DocumentDecoderHelper` and `ImageDecoderHelper` from 23:07 to 23:17, before the run started.

Unowned failure: `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread` failed in four full package runs, with
3 to 77 main-actor turns where it needs more than 100. That was while a draft used Foundation's
`String.folding(options: .caseInsensitive)`. It passed alone and in filtered groups. The final code uses the standard
library's case mapping, and the full suite passed with it. The evidence was added to the test's existing entry in
`spec/flaky-tests.md`. The test is not this run's, and it stays as written.

ADR candidates from the implementer and adr-impact, before the bar: a typed path-read permission joining format 2 with
no bump, redaction by source ownership for every caller, one uniform refusal for any out-of-scope path, the
protected-location list as the one list, and opened paths keeping their resolved roots. Against the bar in the
standards' `design.md`:

- Redaction passes. A caller learns nothing about a user's file outside its read scope, and every applet that shows a
  user's file must keep that. It cuts across the system. Recorded in UTERM-015's Decision Log as Undecided.
- The format-2 kind is a mechanism. ADR-09's "unsupported meanings authorize nothing" already holds the invariant.
- The uniform refusal and the protected list serve the invariant that uniterm never lends its macOS privacy grants to
  a program. UTERM-015's Decision Log already declined that candidate on 2026-11-03.
- Kept roots are an implementation of ADR-08 and ADR-09.

### UTERM-015 M5: `uniterm open`

The implementer built `uniterm open [--socket PATH] [--] path...`. The command joins a relative path to its own
physical working directory and touches no target. A deleted working directory exits 66. The wire moved to
`ScriptProtocol.version` 13 with an `openBegin` and an `openDone` message. The decoder refuses relative, empty,
NUL-holding, and oversize paths. A caller bound to a terminal session gets Allow once or Allow for This Terminal
Session. The session grant is keyed on the session root and its generation, and it is held in memory only. A caller in
no session, tmux and screen included, gets a once-only row. The once-only flag on pending-indicator rows is general,
and `decide` enforces it. A routed open from a program takes no focus.

First-pass checks:
- `make fmt-check`, `make lint`, `make check`, `caffeinate -dimsu make fuzz`, and `build-for-testing` passed.
- The first `caffeinate -dimsu make test-package` run had one failure, in `ExecDriverChannelTests`; see below. The
  rerun passed 2756 tests, with 10 skipped.
- `proposals.py check` reported nothing on UTERM-015. `proposals.py freeze --row-commit <M4 commit>` returned no hunks.

UI tests: the coordinator ran `ScriptOpenUITests` (new), `LaunchServicesOpenUITests`, `OpenPanelUITests`,
`PendingRequestsUITests`, and `ScriptRunUITests` through `cg_run` (ID HGY6RA, 2026-11-17 00:07). All 8 tests passed in
115 s. The run was on the first-pass code.

New test classes:

| Class | Tests | Time |
|---|---|---|
| `ScriptOpenTests` | 11 | 0.16 s |
| `ScriptOpenRunTests` | 6 | 0.63 s |
| `ScriptOpenWindowTests` | 5 | 0.49 s |
| `ScriptOpenCommandTests` | 4 | 0.001 s |
| `ScriptOpenUITests` | 2 | 29.9 s |

Unowned failure: `ExecDriverChannelTests.testAnOversizeClipboardWriteIsRefusedAloneAndOneAtTheBoundArrives` timed out
after 15.5 s in one full package run. It was "waiting until the channel ends or answers both writes and the command
after them". It passed alone in 0.13 s, passed with its class, and passed in the full rerun. The exec driver does not
use the script listener or the wire this milestone changed. It was not tried on the base commit. It stays an open,
load-dependent flake. `spec/flaky-tests.md` already had an entry for it from 2026-11-15, which gained this sighting.

Implementer best guesses and deviations, in the proposal's Decision Log entry "M5 work-queue best guesses":

1. A program's open brings no existing window forward, per ADR-12. The settled text brought the most recently key
   window forward for a caller in no session. It was amended in place.
2. A user's Deny exits 77. Success, missing, and unsupported all exit 0, since the app replies before it looks at any
   path. Exit 0 means only that the app took the request. Deny reveals the user's answer, not anything about a file.
   If wrong, a Deny exits 0 too.
3. There is no bundled-command check. Any program that sends the begin gets the same question, since the authority
   is the terminal session.
4. An argument that is not valid UTF-8 is refused with exit 64, so it is never repaired into another file's name.
5. M5 gained a check that a pane or window `uniterm open` makes takes no focus.
6. A session allow leaves that session's other waiting rows pending, each revalidated when answered.

Review findings and their dispositions:

- A session-bound command whose pane label is gone got no-session wording, but still offered the session button.
  PLAUSIBLE. Sent to trace.
- adr-impact: a new window is ordered front, while the amended text says no window is brought forward. Sent to fix.
  The best guess: a new window holding only the routed pane is ordered front without becoming key, and a split never
  raises its window.
- Deviation 6 was not in the proposal. Sent to fix.
- One As built bullet had a 201-column line. A grant that "ends" on a generation change only stops covering. Both
  sent to fix.
- adr-impact, advisory: the session grant has no revoke action of its own beyond session end and pane close, the same
  as the clipboard session grants. ADR-09 asks for a revocable grant. Recorded for the user.

Fix round outcome:

- The nameless-pane case: the trace confirmed it. Wording, the once-only flag, the denial key, and the stored grant now
  follow one condition: a session whose pane cannot be named counts as no session. The regression test
  `testASessionWhoseCallerCannotBeNamedIsOnceOnlyAndStoresNoGrant` was shown failing on the old condition with 3
  expected failures (`cg_run` R95B32), and passing with the fix (R38T2S).
- New windows: the code orders a new routed window front without making it key or activating the app. The proposal
  text was corrected to say so. A routed split raises no existing window.
- Deviation 6 is now Decision Log item 14. Item 15 records the nameless-pane choice. The As built block was rewrapped
  and says a grant stops covering on a generation change.

Second-round checks: `make lint`, which includes `fmt-check`, and the full `caffeinate -dimsu make test-package` passed.
`make fuzz` and `build-for-testing` were not rerun, since only host logic and one test changed and the wire is
untouched. The coordinator then ran `caffeinate -dimsu make test-helper-sandbox` (ID 5FTH34). It built the app and
passed 9 tests, including the new `testTheShippedCommandResolvesARelativePathForOpen`. The UI classes were not rerun
after the fix round. Their run covered the first-pass code, and the change affects only a pane that vanished mid-open.

ADR candidates:
- The once-only rule for a requester that cannot be tied to a session is declined. ADR-09's last bullet already holds
  it: "A terminal-session request that cannot identify its originating program cannot use a particular script's
  persistent approval."
- The uniform reply falls under M4's Undecided candidate on what a caller may learn about a user's file.

### UTERM-015 M6: Terminal clicks

The implementer added Ghostty patch `ThirdParty/ghostty-patches/003-remote-host-and-raw-link-text.patch`. It adds a
`REMOTE_HOST` action for an OSC 7 that names another host, and it removes libghostty's join and `accessAbsolute` for
clicked link text. Hover and open-URL now reach the app as `TerminalEvent` cases. `OPEN_URL` is always taken, and
`link-url`, `link-osc8`, and `link-previews` are set explicitly.

On Command-hover, an overlay at the bottom-left shows the decoded target. A click opens only the string last hovered.
It goes through an `lstat`, a no-follow open, a device and inode check, and an `F_GETPATH` compare before the router
places the pane. A remote marker covers a terminal tab for its session's life. It is set by a listed remote client in
the session's process tree, tracked by process sources with a 2 s rescan, or by the patched OSC 7.

First-pass checks: `make ghostty` passed through `cg_run`, about 110 s per cold build. `make fmt-check`, `make lint`,
`make check`, `caffeinate -dimsu make test-package` (2805 tests, 10 skipped), and `build-for-testing` passed.
`proposals.py check` reported nothing on UTERM-015, and `freeze` returned no hunks. The patch's relative-text half was
shown necessary: with only the remote-host half, `testCommandHoverAndClickReportTheLinkTextAsPrinted` got the joined
absolute path.

New test classes: `TerminalLinkTargetTests` 14 tests in 0.01 s, `TerminalLinkClickTests` 19 in 0.03 s,
`RemoteClientWatcherTests` 9 in 0.04 s, `ProcessInspectionTests` 5 in 0.003 s. Two new tests in
`TerminalSessionIntegrationTests` took 0.26 s and 0.53 s.

UI tests, first run (`cg_run` 3A5SKG, 2026-11-17 00:42): `TerminalLinkUITests`, `TerminalUITests`, and
`ScriptOpenUITests` ran 15 tests, and 3 failed:

- `TerminalLinkUITests.testCommandClickOnARelativePathOpensNothingAndSaysWhy`: the typed text never reached the first
  row.
- `TerminalLinkUITests.testCommandHoverShowsTheTargetAndCommandClickOpensItBesideThePane`: "Lost connection to the
  application (pid 4564)". No uniterm crash report was written.
- `ScriptOpenUITests.testACommandOutsideEverySessionIsOfferedAllowOnceOnly`: the question never reached the panel. It
  had passed at 00:08 on the M5 code.

All 11 `TerminalUITests` passed. The failures went back to the implementer to diagnose.

Implementer best guesses and deviations, in the Decision Log entry "M6 work-queue best guesses":

1. The marker covers one terminal tab for its session's life, not the whole pane. Each tab is its own session.
2. Text that could show as another path is refused. That covers control, format, separator, and unassigned
   characters, and `file:` links with a query, fragment, or credentials. The overlay shows the raw path,
   middle-truncated, not `sanitized()`, which would collapse a double space into another name.
3. The process tree is tracked with per-process sources plus a 2 s rescan. The plan asked for events only. A setuid
   root such as `login` cannot be watched.
4. Patch 003 adds a new action and leaves the PWD action alone.
5. A click whose text differs from the last hover is refused with a status message.
6. `~` and `$VAR` paths count as relative, and a relative click posts a message. The settled text said it does
   nothing, and it was amended.
7. A click takes focus like File > Open, since it is the user's act.

Review findings and their dispositions:

- Two Rationale sentences contradicted the amended decisions, and "firmlinks such as `/tmp`" is a correction of fact.
  Sent to fix.
- A vacuous assertion in the OSC 7 integration test. Sent to fix.
- No package test showed a click reaching the router, so only the UI tests covered the wiring. PLAUSIBLE. Sent to fix
  with a window-level test.
- A stale preview after a tab switch. Sent to fix.
- An OSC 7 that fails earlier in `reportPwd` sends no host notice. Sent to fix as a known gap.
- Accepted residuals: a click on a dead network mount parks one thread with no bound, and the watcher keys its root by
  PID alone. Recorded in As built.
- adr-impact found no conflict. Advisory: under ADR-12, the routed pane takes focus after the asynchronous check, so a
  late focus move is possible if the user types elsewhere in the gap.

Fix rounds and their outcomes:

- All five review items were fixed. The stale-preview regression test was shown failing on the old code first. The new
  `TerminalClickRouteTests`, 4 tests in under 0.2 s, proves a click reaches a real `RoutedOpener` beside the clicked
  pane.
- The first relative-path UI failure was a test bug. The synthesized apostrophe in `printf '...'` reached the shell as
  a control sequence, which `TerminalUITests` already warns about. The test now types `clear; echo <text>`.
- The second run's lost app was not a crash. The app received a normal terminate, ran for 22 s, and exited 0, and
  nothing in M6 sends one. The sender was not found.
- `ScriptOpenUITests.testACommandOutsideEverySessionIsOfferedAllowOnceOnly` passed on its rerun (`cg_run` V5Z2GR) and
  in later runs. No M6 mechanism for its one failure was found.
- The relative-path test then failed because it matched the status message by prefix, while the bar prefixes each
  message with its source. It now uses `contains`, as `StatusBarUITests` does.
- The overlay truncated a path that fit. The coordinator saw it in the `link-overlay` screenshot. The fix sizes the
  label from the cell's required size. Its unit test failed first with 696.0 against 697.58 points. The coordinator
  then saw the whole path in the next screenshot (`cg_run` W21NB8).
- Both link tests then failed intermittently, 2 of 2 at 01:00 and 4 of 6 at 01:03. The implementer added debug-level
  logging under the `terminal-link` category, which never logs link text, and a wrapper that streams the log during
  the run. Two logged three-iteration runs (9X5FME, DVW2EA) passed 12 of 12. The cause is not established. The entry
  in `spec/flaky-tests.md` has the evidence.

Final-tree checks, run by the coordinator after the last code change:
- `caffeinate -dimsu make test-package` (`cg_run` 6FGNA4) ran 2810 tests, with 10 skipped and 1 failure. The failure
  was the known `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread` flake, at 82 turns. It is in
  `spec/flaky-tests.md`, and M6 touches no text-viewer code.
- `caffeinate -dimsu make ghostty-offline-check` (`cg_run` 1H9S0R) applied patches 001 to 003 and rebuilt GhosttyKit
  `83fb95624b04-zig0.17.0-xcode17F113-sdk26.5-e4755e92` with the network off.

ADR candidates: "libghostty never touches a path a program chose" is covered by ADR-01 and ADR-04 together with this
proposal's settled click rule. "A click acts only on a path the pane showed" governs the terminal applet only. Neither
passes the cuts-across test.

### UTERM-015 M7: Launch Services approvals

The implementer replaced M2's refusal of other senders with a question in the pending indicator.
`OpenAuthority.decide` returns `.userAct` or `.needsApproval(sender:onceOnly:)`. Every Apple-anchored non-opener, an
unidentified sender, and a sender with no signing identifier are once-only. A third-party signed app can be allowed
until it quits. That grant binds to the PID and PID version, lives in memory, and ends on exit or exec. One event is
one question. It names the sender, lists every full path, and covers the count. An approved open takes no focus and
raises no existing window. A busy queue, a Deny, a withdrawal, and an event with no local file each post the coalesced
refusal message. A question waiting at cold launch lets the default window open.

First-pass checks: `make fmt-check`, `make lint`, `make check`, `caffeinate -dimsu make test-package` (2825 tests, 10
skipped, 0 failures), and `build-for-testing` passed. The freeze check showed one hunk with origin `other`, in
UTERM-004's References, adding ADR-14. That is another session's edit, left for the user.

UI tests: the coordinator ran `LaunchServicesOpenUITests` (rewritten), `PendingRequestsUITests`, `OpenPanelUITests`,
and `ScriptOpenUITests` (`cg_run` 87X0E1, 2026-11-17 01:37). All 7 tests passed in 121 s. The runner's NSWorkspace
open now raises a question that the test approves, and the routed pane opens with the first pane still focused. A
second test denies and sees the message.

New test classes: `LaunchOpenApprovalTests` 16 tests in 0.94 s. `LaunchOpenCoordinatorTests` is now 8 tests in 0.56 s,
and `OpenAuthorityTests` 8 tests in 0.001 s.

Implementer best guesses, in the Decision Log entry "M7 work-queue best guesses":

1. Every Apple-anchored non-opener, and a sender with no signing identifier, is once-only. No helper identifier is
   named. If wrong, an Apple-signed app the user drives is asked on every open.
2. A session grant also ends when the sender execs.
3. A Deny of an app lasts until the app ends. A Deny of a go-between or an unknown sender is not remembered, so one
   denied `open -a` does not block the next.
4. Only senders that can hold a session grant are watched, so only their questions are withdrawn on exit. A
   go-between exits right after it sends, and withdrawing it would refuse every `open -a`.
5. An event with no local file is refused with its own message. A mixed event asks about the files and says how many
   items will not open.

Review findings and their dispositions:

- Once-only events each made a new requester, so a flood of them could fill all 64 pending rows and starve OSC 52,
  script, and controller questions. CONFIRMED. Sent to fix with a class cap at the per-requester bound, as a best
  guess.
- The real watcher's claim that an already-exited sender ends at once was unmeasured. PLAUSIBLE. Sent to trace with a
  real exited process.
- adr-impact, under ADR-14, which another session accepted during this run and which supersedes ADR-09: "Opening a
  window is a power of its own". The question said only "each in a new pane", though an approved open can make a
  window. Sent to fix in the question text and the proposal.
- A one-second sleep in the UI test guarded a check the package tests already own. Sent to fix.
- Recorded for the user: a Deny can fold into an earlier coalesced message within 30 s. A non-Apple interpreter, such
  as a Homebrew `python3`, can hold a session grant that covers whatever script runs in it until it exits or execs.

Fix round outcome:

- Once-only flood: fixed. Every `.launchEvent` now counts against one shared `maxRowsPerRequester` bound. The
  regression test `testAFloodOfOneEventRequestersLeavesRoomForAnotherRequester` failed first three ways: 64 rows
  instead of 16, a full queue, and a clipboard question refused as busy. Distinct live signed apps each still bound
  alone, so many of them could still fill the rows. That is recorded as a residual.
- ADR-14: the question now says a new window opens when a batch or a lack of room calls for one. The proposal gained a
  bullet and a check that cite ADR-14, and a References entry. A session grant also covers such a window.
- The UI test's sleep is gone.
- Exited-sender watch: the trace did not confirm it. `SenderWatcherTests` spawns `/usr/bin/true`, waits for its exit,
  and then watches. The real watcher fired in 0.08 s. No liveness check was added, and the test pins the behavior.

Second-round checks: `make lint`, `make check`, `caffeinate -dimsu make test-package` (2828 tests, 10 skipped, 0
failures), and `build-for-testing` passed. The coordinator reran `LaunchServicesOpenUITests` and
`PendingRequestsUITests` (`cg_run` P4GEVR, 2026-11-17 01:46), and they passed. New: `SenderWatcherTests` 2 tests in
0.19 s.

ADR candidates: adr-impact named "nothing touches a path before an outside caller is approved". UTERM-015 declined it
on 2026-11-03 as "uniterm never lends its macOS privacy grants to a program". It is not re-recorded.

## Status

In progress.
