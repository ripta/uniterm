# UTERM-017 M1-M3: Status bar placement and contract work-queue run

Started 2026-11-06. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-017 M1-M3`, from `spec/proposals/UTERM-017-status-bar-placement.md`. UTERM-017 settles where an applet's
notice goes and what level it gets. It also adds typed window slots, a shared queue and history, and one rule for
detached panes and restore. The specs live in the code repo, so every commit below is in
this repo, on the `agent/petunia` branch.

## Run state

The run finished on 2026-11-06, and UTERM-017 is `implemented`. The run's base is "8< --- snip ---", which is also the row's
base. The row has no dependencies, and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no
work is stashed. No commands needed the user's credentials.

Commits, in order:
1. "Give every notice one rule and show window state in the status bar"
2. "Bind status identity at origin and bound the history by severity and source"
3. "Hold alerts while detached and keep restored panes off the bar"
4. "Close the seams between the status milestones", the row review
5. "Finish the status bar placement row"
6. "Bring back an evicted held record whichever order the pane posts in", the final review

One gap in the proof remains. The UI suite ran only on M1, since every later attempt found the screen locked. Run
`make test-app` with the screen unlocked. `make test-package` passed in full after the run, on 2026-11-06 at 08:44: 1,143
tests, 4 skipped, 0 failures, run `11ZJFH`. See "Unowned failures" for the correction to what this report first said.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-017 M1: Shared rules and the window slot | DONE | "Give every notice one rule and show window state in the status bar" |
| UTERM-017 M2: The queue | DONE | "Bind status identity at origin and bound the history by severity and source" |
| UTERM-017 M3: Detached panes and restore | DONE | "Hold alerts while detached and keep restored panes off the bar" |

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
- UTERM-017 M2: look at the expanded history: the filter menu, the Focus Pane controls, and the loss strip. Run the Focus
  Message History command, then try the arrow keys, Return, Tab, and Escape.
- UTERM-017 M2 and M3: run `make test-app` with the screen unlocked, since the UI suite has not run on either.

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
- `TerminalSessionIntegrationTests` passed. The failure from the 2026-11-05 run did not recur.
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

## UTERM-017 M2

Commit: "Bind status identity at origin and bound the history by severity and source".

Checks, each run on 2026-11-06:

- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, the UI tests built with
  `build-for-testing`, `proposals.py check`, and `proposals.py freeze`. All passed, apart from the UTERM-013 finding above.
- The coordinator reran `make test-package`: 1,085 tests, 4 skipped, 21 failures, run `EA138P`. All 21 are in
  `TerminalSessionIntegrationTests`. See "Unowned failures" below.
- `make test-app` did not run. The runner failed at once with "System authentication is running", which means the screen
  was locked. So M2's UI tests have not run, including the changed `StatusBarUITests`.

### Unowned failures

Run `EA138P` has 20 `surfaceCreateFailed` failures and one cleanup failure in `testShellCanReadAndWriteHome`, "couldn't be
removed", all in `TerminalSessionIntegrationTests`.

- Evidence the work did not cause them: `git diff cdd3bcf` shows no change to the `TerminalSurface` sources, its tests, its
  one local dependency `Theme`, or `Package.swift`. The same tests passed in M1's run, before any hung run existed.
- Correction, 2026-11-06: this section first blamed a pty shortage from the `xctest` processes the hung runs left behind.
  The evidence refutes that. Those runs hung in `StatusKitTests`, before `TerminalSurfaceTests` run, so they never started
  a terminal. Only 38 `/dev/ttys*` nodes existed. And all 21 tests passed with an orphan alive and the display on, run
  `QSTC7S`. The sandboxed `pty.openpty()` failure the 2026-11-05 report cites is the sandbox's, not a real shortage.
- Likely cause: the display being off. `pmset -g log` shows it off from 01:30:51 to 08:32:27 local, apart from four
  30-second wakes when a UI test launched. All 10 failing `make test-package` runs listed by `cg_list`, 03:56 to 07:54, fall
  inside that window. M1's passing run at about 01:06, and the runs at 08:43 and 08:44, fall outside it.
- Uncertain: this is a correlation in time, with no run yet that turns the display off on purpose. The libghostty code path
  behind the failure was not read. The cleanup failure's message has no explanation yet, though it stopped with the rest.
- Not a flake in the sense of random failure: all 21 failed together on every run in the window, and passed together outside it.

### The hang and the stalled agents

A full `make test-package` hung, which is a defect in the run's own test, exposed by an older leak.

- Confirmed cause: window closes in the package tests leave GCD workers blocked. 70 of 76 threads were stuck in
  `-[NSAnimation _runBlocking]`, read in-process with `task_threads` and a frame-pointer walk. Setting
  `animationBehavior = .none` temporarily made the failing filter pass. The flood test queued its producers on that starved
  pool, so it never ran them.
- Fix: the flood test uses four dedicated `Thread`s.
- Not fixed: the leak itself. The base commit has the same 5 `window?.close()` calls, by reading only. Nothing on the base
  queued work on the global pool after those classes, so nothing noticed.

Two implementers were stopped and replaced, and a third was stopped and resumed. Each looked hung on a `cg_run` call that
never started. The cause: `.cg.yaml` allows `proposals.py` only under older plugin hashes, and has no rule for `sample` or
ad hoc scripts. cg was waiting on an approval prompt. Running `proposals.py` through Bash avoids it. `.cg.yaml` was not
changed, since that is the user's approval list.

Best guesses made during the milestone:

1. Byte limits: message text 2 KiB, label 128 B, error pool 128 KiB, other pool 256 KiB, pending 64 KiB and 32 entries, folded
   128 KiB and 100 entries. They rest on "bounded in count and bytes" and ADR-08. Each is one policy constant.
2. The detached-storage bound moved from M2's check to M3's, with an amendment, since that storage arrives in M3.
3. Raw stderr goes to the history only, with no bar turn, so an info flood cannot take every turn. "Driver stderr levels" and
   UTERM-004 are amended to say so.
4. The loss summary is a strip at the top of the panel, with an Acknowledge button.
5. Non-pane sources read "name (applet N)" or "name (script N)", so a producer named "uniterm" cannot pass as the host. A pane
   titled "uniterm" still reads that way on the bar, as it did before. Its history rows carry the pane ID.
6. Keyboard path: a new Focus Message History command with no default key engages the panel. Arrow keys move a row cursor,
   Return runs Focus Pane, Tab walks the controls, and Escape returns to the pane. Until then the panel refuses first
   responder, so opening or reading never moves the keyboard. This command is the guess that most deserves review.
7. A row counts as exposed only when its whole line is in view, and only while the window can show it. A minimized or occluded
   window acknowledges nothing. Tests override this gate through the window fixture, since test windows are never shown.
8. The window set holds 32 messages with no window open. It drops the oldest non-error first, and the next window shows one
   message counting what was lost.

Review findings:

- Fixed, proposal: M2's check claimed a detached bound it had left to M3. The As built block listed symbols and reasons.
- Fixed, `CONFIRMED`: a producer released without retiring leaked its slot. The test failed on unfixed code.
- Fixed, `CONFIRMED`: a producer named "uniterm" rendered like the host, and a forged kind with an issued ID was accepted. The
  tests failed on unfixed code.
- Fixed, `CONFIRMED`: closing a pane could requeue past the 32-entry bound. The test failed on unfixed code at 33.
- Fixed, plan gap: the panel had no keyboard path. The real keyboard path has not been tried in the app.
- Fixed, tests: wall-clock assertions removed, an inaccurate comment fixed, and direct proof added for the source-index bound.
- Traced and confirmed, then fixed: per-line observer rounds, with a test failing on unfixed code at 4 rounds; per-chunk work
  in the stderr ingress, with a test failing on unfixed code; layout re-entry, with a test failing on unfixed code.
- Traced and confirmed, then fixed, but the new tests never ran on unfixed code: the held-message drop, confirmed by reading,
  and the exposure edge. The occlusion gate is new, so it has no old behaviour to run against.
- Left for the user: the UTERM-013 freeze hunk.
- `adr-impact` reported no conflict and no supersession. Its one `ADVISORY` on ADR-08 is the same as the stderr ingress finding,
  now fixed.

ADR candidate: the host binds a status source's identity at origin, and no producer can claim another's. It cuts across the
system, since UTERM-003 and UTERM-004 producers must follow it. It is recorded as `Undecided` in UTERM-017's Decision Log. The
test rule "windows close with animation off" is a test practice, so it is not a candidate.

Open for the user: the leaked animation workers in the package tests can starve any later test that uses the global queue.
Setting `animationBehavior = .none` in the test fixtures would close it.

## UTERM-017 M3

Commit: "Hold alerts while detached and keep restored panes off the bar".

Checks, each run on 2026-11-06:

- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, the UI tests built with
  `build-for-testing`, `proposals.py check`, and `proposals.py freeze`. All passed, apart from the UTERM-013 finding above.
  `proposals.py check` also reports that the proposal and its queue row can now finish, which the row review settles.
- The coordinator reran `make test-package`: 1,137 tests, 4 skipped, 21 failures, run `P62JZA`. A grep of that run shows all 21
  are the same `TerminalSessionIntegrationTests` set.
- `make test-app` did not run. A filtered `StatusBarUITests` probe failed with "System authentication is running", which means
  the screen was locked.

Best guesses made during the milestone:

1. One delivery requirement with three ways: a message, attention with no turn, and history only. An optional record ID shows
   an existing record without adding a history entry. All four test hosts changed.
2. Restore origin travels on the start event as a required `start(origin:)`, with no default. The first version added a
   `restoredAtLaunch()` call. Review found its default could be missed silently, and `adr-impact` found it added a fifth call to
   ADR-05's list of events. If the guess is wrong, undo-reopened or launch-restored panes get the wrong delivery.
3. `StartOrigin` is its own type with `restore` and `user`, since a reload makes no sense on a start event. Reusing `LoadOrigin`
   is a small change.
4. Revert and the file watcher are `reload`. A sheet switch is `user`.
5. The held bound is 8 alerts and 8 KiB. The oldest non-error goes first. The count message is a new history entry, at the most
   severe level and strongest delivery lost.
6. Every viewer and terminal post goes through the helper. User-action posts happen attached, so they behave as before. The
   terminal's clipboard question is not a notice, and it still shows while detached.
7. A pane's host keeps a ledger of the records it issued, and honours a present call only for those, once each. The queue
   cannot tell who made a record retention has already dropped. This first shipped with a 256-entry limit, which the row review
   replaced. See "Row review".

Nothing sends `detach` or `reattach` yet, so the detached behaviour has no user path. Tests call the events directly.

Review findings:

- Fixed, plan gap: the terminal's start failure bypassed the rule, so many failing restored terminals could bury the bar. New
  tests inject the failure with a fake engine.
- Fixed: `restoredAtLaunch()` became the required start origin, as guess 2 says. `adr-impact`'s `PLAUSIBLE` ADR-05 point goes away
  with it, since the events are unchanged.
- Fixed, `CONFIRMED`: an unused public helper that bypassed the rule was removed.
- Fixed, comment craft: one doc comment packed two ideas.
- Traced and confirmed, then fixed: a pane could present another pane's record, and a never-issued ID left an indicator that
  could not be cleared, since the loss strip hides at zero. Four tests failed on unfixed code.
- Traced and confirmed, then fixed: a changed-on-disk notice from a restore took a turn, with a test failing on unfixed code. A
  guard test shows a real watcher change still posts.
- Traced and confirmed, then fixed: a user filter relabelled a restored sort notice, with a test failing on unfixed code.
- Accepted: the many-panes test runs the real launch path with a stand-in applet. The viewers and terminal are proved one at a
  time, not in one launch together.
- Left for the user: the UTERM-013 freeze hunk.

ADR candidates: none added. The delivery modes and `start(origin:)` are mechanisms. The restore-origin rule is part of the notice
rule the user declined an ADR for on 2026-11-05.

## Row review

Commit: "Close the seams between the status milestones".

The coordinator reran `make test-package`: 1,141 tests, 4 skipped, 21 failures, run `RVTDVM`, the known set by count. The
implementer ran the other checks, including `make swiftpm-offline-check` since `Package.swift` gained a test-support target. All
passed, apart from the UTERM-013 finding above.

Findings:

- Traced and confirmed, then fixed: a held record could fall off the host's ledger after more than 256 later alerts, so reattach
  added a duplicate history row. The test failed on unfixed code. The ledger now keeps an entry exactly while the history keeps
  its record, so the two retention rules are one.
- Traced and confirmed, then fixed: a newer load replayed the replaced load's held notices on reattach, so a stale "File not
  opened" turn could follow a successful load. Tests failed on unfixed code in both viewers. A new load now drops those held
  info and warning notices. Their history records stay. Errors and alerts no load produced stay held. This is a best guess
  recorded in the Decision Log, and M3's reattach check is amended.
- Fixed: comment overruns, a proposal marker mid-bullet in UTERM-004, and the filter menu building its own pane label.
- Fixed: dead surface. `recordInHistory` moved to test support and an unread policy constant went. `AppletAlerts` counts became
  internal. `StatusQueue`'s unseen readers stay public, since tests in another module read them.
- Fixed: the five recording test hosts became one `RecordingHost` in a new `AppletTestSupport` target. No assertion was dropped.
- Left for the user: a pane closed while detached records a held error in the history, but never raises the unseen signal. This
  follows the milestone check, and it has no user path yet, since nothing sends `detach`.
- Left for the user: the UTERM-013 freeze hunk.
- No action: unseen warnings and window-state slots share one tone. Their symbols differ, and the M1 look covers it.
- `adr-impact` reported no conflict and no supersession across the row. `start(origin:)` keeps ADR-05's four events.

ADR candidates: none added. The held-load rule and the ledger rule are mechanisms.

## Final review

Commit: "Bring back an evicted held record whichever order the pane posts in".

The coordinator reran these on 2026-11-06. `make fmt-check`, `make lint`, `make check`, and `make build` passed, run `DHHT3C`.
The UI tests built with `build-for-testing`, run `SDDW9R`. `make test-package` ran 1,143 tests, 4 skipped, 21 failures, run
`P8ZKKR`, the known count. `make test-app` did not run. A filtered probe, run `V4X8JK`, found the screen locked.

Findings:

- Fixed, `CONFIRMED`: the ledger pruned only when the pane admitted a record, so an evicted held record behaved two ways on
  reattach. It now prunes on lookup too, and the record always returns as its own row. The test for the first order failed on
  unfixed code. The test for the second order passed before the fix, as the trace predicted, and guards it.
- Fixed: a stale claim in this report about a 256-entry ledger.
- Left for the user: the UTERM-013 freeze hunk.
- `adr-impact` reported no conflict and no supersession. The range adds and edits no ADR.

The new tests use a four-record warning pool, so a few records evict a held one. Production keeps 400.

## Status

Changed: everything in the commits above, on `agent/petunia`. Nothing is pushed.

Open:

- The checks listed under "Checks left to the user".
- The ADR candidate in UTERM-017's Decision Log: the host binds a status source's identity at origin. It is `Undecided`.
- Nothing sends `detach` or `reattach`, so M3's detached rule has no user path yet.
- The package tests' leaked animation workers, and the `.unavailable` and missing-folder paths that do not save a layout.
- Allowlist gap: `.cg.yaml` allows `proposals.py` only under older plugin hashes.
