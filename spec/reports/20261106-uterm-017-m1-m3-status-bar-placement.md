# UTERM-017 M1-M3: Status bar placement and contract work-queue run

Started 2026-11-06. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-017 M1-M3`, from `spec/proposals/UTERM-017-status-bar-placement.md`. UTERM-017 settles where an applet's
notice goes and what level it gets. It also adds typed window slots, a shared queue and history, and one rule for
detached panes and restore. The specs live in the code repo, so every commit below is in
`/Users/ripta/projects/uniterm`, on the `agent/petunia` branch.

## Run state

The run is in progress. The run's base is "8< --- snip ---", which is also the row's base. The row has no dependencies,
and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no work is stashed. No commands
need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-017 M1: Shared rules and the window slot | DONE | "Give every notice one rule and show window state in the status bar" |
| UTERM-017 M2: The queue | QUEUED | |
| UTERM-017 M3: Detached panes and restore | QUEUED | |

## Local checks

The implementer runs `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package`. It runs
`make swiftpm-offline-check` when `Package.swift` changes, and builds the UI tests for testing. Then it runs
`proposals.py check` and `proposals.py freeze`. The coordinator reruns `make test-package` before each commit. It runs
`make test-app` through cg, after a filtered probe that shows whether the screen is locked. It also checks the
crash-report folder for new uniterm reports.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. Nothing in the host sends `detach` or `reattach`. UTERM-001 M10 records this as intended. M3 builds the rule and proves
   it by calling the events in applet tests. It adds no host trigger, so the behaviour has no user path yet. If the guess
   is wrong, a new proposal adds the trigger.
2. Undo reopen goes through `init(restoring:)` but is a user action. The launch restore path sets restore origin. If the
   guess is wrong, a reopened pane's notices go quiet.
3. A file-watcher reload is neither restore nor a user load, so origin has a third case. Reloads post normally. If the
   guess is wrong, the third case merges into user.
4. The "Layout not saved" slot covers the second instance only, as M1 names. The `.unavailable` and missing-folder paths
   also do not save, and they keep their error posts.
5. A map file failure with no tiles and no command-layer pins is an empty pane, so the pane explains it.
6. An empty-pane history entry raises no unseen signal, since the pane already says it. Its level is the typed failure
   level. A failed load is a warning unless user work is lost.
7. Tile failures are not loads, so they carry no origin. They stay once per outage. A restored offline map posts at launch
   as it does today, and its segment holds.
8. A refused map edit that also wipes the undo stack may be lost user work, which would make it an error. The implementer
   confirms what is lost, then picks the level.
9. History-only delivery lands in M1 rather than M3, because M1's empty panes need it.
10. Overflow order: applet segments compress before slots and the message.
11. Focus Pane is a per-row control in the history panel, not a registry command.
12. Host-bound identity lands in M2. M2's checks need it, and M3's close path depends on it.

## Checks left to the user

- UTERM-017 M1: look at the bar with the slot showing, in both dock positions and a narrow window. Hover each window slot
  for its tooltip, since no headless test can show one.

## Edits found but not made

- `spec/proposals/UTERM-013-shortcut-ownership-and-reopen.md` line 70 carries a "Superseded in part by UTERM-016" marker
  wrapped across two lines. `proposals.py freeze` reports it with origin `other`. It predates this run, so it is left for
  the user.

## UTERM-017 M1

Commit: "Give every notice one rule and show window state in the status bar".

Checks, each run on 2026-11-06:

- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, the UI tests built with
  `build-for-testing`, `proposals.py check`, and `proposals.py freeze`. All passed, apart from the UTERM-013 finding above.
- The coordinator reran `make fmt-check` and `make test-package`: 1,022 tests, 4 skipped, 0 failures.
- The coordinator ran `make test-app`: 97 tests, 0 failures, in 790 s.
- `ls -lt ~/Library/Logs/DiagnosticReports` showed no uniterm crash report.
- `TerminalSessionIntegrationTests` passed. The pty shortage from the 2026-11-05 run did not recur.
- `make swiftpm-offline-check` was not run, since `Package.swift` did not change.

Best guesses made during the milestone:

1. Failed terminal starts, program starts, and tab opens moved from error to warning, since no user work is lost. This
   rests on UTERM-017 "Notice levels". A start failure that closes the pane now shows only a 5-second warning. If the guess
   is wrong, each post is a one-word revert.
2. The viewers' file-open catch blocks moved from error to warning. Both are unreachable today, since no `replaceSource`
   throws. They stay because the protocol allows a throwing conformer.
3. A failed map save stays an error. The level rule did not literally cover unsaved pins that are still held, so UTERM-017
   now reads "Lost user work, including work that cannot reach disk, is an error". That wording change is a run best guess.
4. A refused map edit stays a warning. The refused edit and the undo stack are lost. Earlier unsaved pins and the file are
   kept, and a test pins this. This settles run-level guess 8.
5. A data viewer memory stop with no rows counts as an empty pane. A map's empty pane means the tiles report failure and no
   command layer has a pin, decided on each refresh.
6. The cut-rows notice waits for the load to settle, then posts once with the final count. A segment shows the live count
   meanwhile. `AppletNotice` gained a `key` separate from its text, so dedupe no longer depends on the text.
7. The window state reaches the window set from layout persistence, which already holds the set. `AppDelegate` is unchanged.
8. UTERM-005's failed downloads became warnings by amendment, since no user work is lost when a remote file does not arrive.

Deviation from the plan: the plan's M1 item 8 says the minimum window width accounts for the narrow bar. The work leaves
the minimum width alone, since it comes only from the pane tree. The proposal's check still holds at the real minimum
width, and `testEveryWindowStateStaysDiscoverableAtTheMinimumWidth` proves it. The UTERM-017 Decision Log records this.

Review findings:

- Fixed: three amendment lines ran past 120 columns in UTERM-003, UTERM-004, and UTERM-008, with markers mid-paragraph.
- Fixed: the M1 As built text and Decision Log worded the failed-save rule two ways.
- Fixed: the M1 As built block named the unrelated UTERM-013 marker. It moved to this report.
- Left for the user: hover tooltips. The verdict was `PLAUSIBLE`. A subview's tooltip rect should fire despite the bar's
  `hitTest`, but nothing headless can confirm it. It joins the M1 look above.
- `adr-impact` reported no conflict and no supersession. Viewers still post while detached, which M3 fixes.

ADR candidates: none added. The level and placement rule was already declined on 2026-11-05. The typed window slots are a
mechanism, so they fail the Architecture test in `design.md`.

Regression proof: the implementer reverted five fixes and saw the matching tests fail for the right reason. They were the
refresh at load start, the clear resetting its counts, the settled gate on the cut notice, the sheet-switch reset, and the
narrow-bar fit. `testALoadReplacedInFlightNeverReportsItsFailure` passes on the old code too. The generation guard already
protected that path, so that test pins behaviour rather than covering a bug.

Open for the user: the `.unavailable` and missing-folder paths also do not save the layout, and they keep their error posts
rather than a slot.

## Status

In progress. M1 is committed. M2 and M3 remain.
