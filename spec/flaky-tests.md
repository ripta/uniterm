# Flaky Tests

This document tracks UI and unit tests that fail without a code change. It lists potential flakes and records the
fixed ones.

## Rule

- A test that fails in a run and then passes when rerun alone is a potential flake. List it under "Potential".
- A test that fails again when run alone is a confirmed flake. Fix its cause in the test or the product.
- A fixed flake moves to "Fixed". Its entry names the fix by commit subject.
- A failure that reproduces reliably is a bug. File it under `spec/bugs/`.
- Never fix a flake with retries, longer timeouts, or weaker assertions.

## Potential

### `DataViewerUITests.testEditFindExistsAndIsDisabledWithNoFile`

- Seen: 2026-11-07, once in a full suite.
- Evidence: `DataViewerUITests.swift:365` failed with "Invalid parameter not satisfying: point.x != INFINITY" when
  clicking Edit > Find. The test passed 6 of 6 alone.
- Suspected cause: state in the menu bar left by earlier tests in the suite.
- Checked: a closed menu is not the cause. With the Edit click removed, XCUITest opened the menu path itself and the
  test passed. A menu item has no frame when the app's menu bar is not on screen, so uniterm may not have been
  frontmost. That fits the lost-key entries above.
- Status: unresolved. The test now waits for the item to take a click, and the failure names the app's state, the
  frontmost app, and the focused element.

### `PaneTreeUITests.testFocusMovesWithTheKeyboardAndInputReachesOnlyTheFocusedPane`

- Seen: 2026-11-07, once in a full suite.
- Evidence: `PaneTreeUITests.swift:59` failed. The typed `echo "L:$((6*7)):"` never showed in the focused pane within
  20 s. The test passed 3 of 3 alone.
- Suspected cause: keys sent right after Cmd-Option-Left moved focus went nowhere. This is the same pattern as the fixed
  Cmd-W flake.
- Checked: `PaneAreaView.focus()` moves the focus mark and the first responder in one synchronous call. The test's
  wait for "focused" cannot run ahead of the responder, so a race inside the app is unlikely. Something outside the
  app taking the keyboard fits better, such as another session's UI run or a system prompt.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `PaneTreeUITests.testReopenBringsBackTheClosedPaneFromItsDescription`

- Seen: 2026-11-07, once in a full suite, in the same run as the entry above.
- Evidence: `UnitermUITestCase.swift:142` found no `pane-2`. The test passed 3 of 3 alone.
- Suspected cause: the pane-opening key went nowhere, as in the entry above.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `MapViewerUITests.testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins`

- Seen: 2026-11-08, once, in a run of `TextViewerUITests` and `MapViewerUITests` together.
- Evidence: the shared open-panel helper at `UnitermUITestCase.swift:227` failed with "no go-to-folder sheet" after
  Cmd-Shift-G. The cg server restarted while that run was going. `MapViewerUITests` then passed 8 of 8 alone.
- Suspected cause: Cmd-Shift-G sent before the open panel took key focus, as in the pane-tree entries above.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `TerminalLinkUITests` (both tests)

- Seen: 2026-11-17, during the UTERM-015 M6 work-queue run. At 01:00, both tests failed in one run. At 01:03, a
  three-iteration run failed 4 of 6: the relative-path test 3 of 3, and the hover test 1 of 3.
- Evidence: "no overlay with Command held over the path" (`TerminalLinkUITests.swift:62`, then `:77`), and "the
  message does not say why. It reads" with an empty status message (`:107`, then `:120`). The UI hierarchy showed the
  printed path in the terminal, an empty status message, and no overlay, so no link hover reached the app.
- Not reproduced: two later three-iteration runs with the debug `terminal-link` log streaming passed 12 of 12. The log
  showed each relative click refused as relative and each absolute click opened. Between the failing and passing
  runs, only the test's pointer moves and the debug logging changed.
- Known mechanism, not proven to be this one: libghostty drops a pointer move within 1 px of its stored position, so
  a hover that starts on the target sees no link. The test now moves across cells before it hovers. A real pointer
  moved by a person during the run would also break the synthesized hover.
- Status: unresolved. If it fails again, run the tests with `log stream --level debug` on the `dev.uniterm.app`
  subsystem, and read the `pointer`, `press`, `hover`, and `click outcome` lines of the failing iteration.

### `BrowserUITests.testCommandWClosesTheTabAndCommandShiftTReopensIt`

- Seen: 2026-11-12, once, as the first test of a full `make test-app`.
- Evidence: `BrowserUITests.swift:166` failed with "Cmd-Shift-T brought no tab" after 49.8 seconds. The other 157
  tests passed. `BrowserUITests` then passed 12 of 12 alone, this test in 11.6 seconds.
- Suspected cause: a cold first launch of WebKit at the start of the suite. Not confirmed.
- Status: unresolved.

### `TextViewerUITests.testAnEditedFileReloadsInPlaceAndByRename`

- Seen: 2026-11-15, once, in the second CI `app` run of PR #49, which does not touch the open-panel helper.
- Evidence: the shared open-panel helper at `UnitermUITestCase.swift:308` failed with "the go-to-folder sheet never
  closed". The other 157 UI tests passed. `TextViewerUITests` then passed 13 of 13 alone. The same message failed
  `DataViewerUITests.testCommandORoutesACSVFileToTheDataViewer` on PR #43's first CI run. It failed
  `DataViewerUITests.testCommandOOpensAWorkbookAndTheSheetPickerSwitchesSheets` on PR #53's first CI run, which does
  not touch the helper either. The rerun passed.
- Suspected cause: Return reached the go-to-folder sheet before it accepted the pasted path. Not confirmed.
- Status: unresolved.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `LauncherUITests.testAShortPaneKeepsTheFilterBoxAndScrollsToTheLastEntry`

- Seen: 2026-11-15, once, in the first CI `app` run of PR #53, which does not touch the launcher.
- Evidence: `LauncherUITests.swift:199` failed with "the scroll wheel did not scroll the list". The rerun passed.
- Suspected cause: the test checks `isHittable` right after the scroll, with no wait for the list to settle. Not
  confirmed.
- Status: fix applied by "Wait for the launcher's last entry to come into view after a scroll". Both reads after a
  scroll now wait until the entry can take a click. No forced slow scroll reproduced the failure first, so the change
  pins the fix but does not prove the cause. Move this entry to "Fixed" if it stays quiet.

### `ControllerConsentUITests`, several tests, after the strict and unsafe modes landed

- Seen: 2026-11-15, in four local runs during the work-queue run that added strict and unsafe script modes. Each run
  failed a different test, and every test passed in at least one other run of the same code:
  - `testAPlainScriptsQuestionNamesItsRun`, `testControllersAndPermissionsShowsAndRevokesTheApproval`, and
    `testThePanelAllowsOnceAndDeniesAReview` failed in one five-class run. All three passed together when run alone.
  - `testThePanelTrustsAVersionThatThenRunsWithoutAsking` failed with "the window never showed the review. The shell
    wrote none. Standard output: none Standard error: none". The typed shell line never ran.
  - `testADeclaredFilesReviewAndApprovalReachThePanelAndTheWindow` exceeded its 1-minute allowance as the first test of
    a class-only run.
- Evidence: the class passed 7 of 7, four times, before the change. The change made each test's run wait for a review,
  and added two tests. The failure messages now report what the shell and the command wrote.
- Suspected cause: lost keystrokes or focus races between app instances, or a system prompt holding the first test.
  Not confirmed, and not reproduced on the commit before the change.
- Seen again: 2026-11-18, in the CI `app` rerun of PR #67. `testAPlainScriptsQuestionNamesItsRun` passed every panel
  step, then `ControllerConsentUITests.swift:379` read `""` where `exit=0\n` was expected, 0.5 s after Deny.
- Partial fix: "Wait for a status file's whole line before reading it". The shell's `echo ... > file` creates the file
  empty before it writes, and `waitForFile` returned whatever it read first. It now waits for the line's newline. That
  answers an empty read only. The other failures above carry other messages.
- Status: unresolved.

### `PendingRequestsUITests.testADenialReachesTheProgramAndClearsTheIndicator`

- Seen: 2026-11-15, once, in a five-class local run. It passed in the run before.
- Evidence: "Unable to find hit point for ScrollView, {{20.0, 749.0}, {739.0, 180.0}}".
- Suspected cause: the scroll view was covered or still moving when the test clicked it. Not confirmed.
- Status: unresolved. Both row clicks into the Pending Requests panel now wait for the row to take a click, and the
  failure names the app's state, the frontmost app, and the focused element.

### `WindowsUITests.testCommandWClosesOnlyTheKeyWindow`, after its fix

- Seen: 2026-11-15, once in a full `make test-app` run during the UTERM-007 M5 work-queue run, the only failure of 165.
- Evidence: `WindowsUITests.swift:120` failed: `echo "K:$((6*7)):"` produced no output in 20 s after a click on the
  first window. That is the full-suite symptom the fix in "Fixed" below names. `WindowsUITests` passed 6 of 6 alone
  right after, on the same tree.
- Status: the earlier fix covered the foreground read. This symptom came back once. Cause unknown.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

### `ExecPaneUITests.testWindowShortcutsWorkWhileTheDriverStalls`

- Seen: 2026-11-15, once in a filtered run of five UI classes during the UTERM-007 M5 work-queue run, the only failure
  of 20 tests.
- Evidence: `ExecPaneUITests.swift:185` failed with "Cmd-D did nothing while the driver stalled". The trail showed the
  app slow throughout: 30 clicks on Next took 13.37 s, and Cmd-D took 15.22 s. It then passed 3 of 3 alone, and its
  class passed whole, on the same tree.
- Status: unresolved. That run changed the exec wire's hello decoding and moved the exec protocol to 4. It also
  revalidates pending replies when remote control turns on. Neither was ruled out by a run on the base commit.
- Next sighting: the failure message now names the app's state, the frontmost app, and the element with keyboard
  focus. UI runs also wait for each other now, so a run from another session cannot share the screen.

## Fixed

### `ExecDriverChannelTests.testAnOversizeClipboardWriteIsRefusedAloneAndOneAtTheBoundArrives`

Fixed by: "Join a driver's stderr line that arrives in pieces, and show a lone partial line after a pause"

- Seen: 2026-11-15, once in a full `make test-package` run during the UTERM-007 M5 work-queue run.
- Evidence: it timed out waiting on the channel. It passed alone and with its class, in 8.5 s, and in the next full
  runs. It launches a real perl driver, so a loaded machine slows it.
- Seen again: 2026-11-17, once, in a local full `make test-package` run during the UTERM-015 M5 work-queue run, which
  touches the script listener and its wire, not the exec driver. It timed out after 15.5 s "waiting until the channel
  ends or answers both writes and the command after them". It passed alone in 0.13 s, with its class, and in the next
  full run.
- Seen again: 2026-11-17, in full `make test-package` run KE15J2 during the UTERM-015 M6 work-queue run. The history
  held `"got error"` and `"bad-argument"` as two entries, where the wait looks for the one line
  `"got error bad-argument"`.
- Cause: a product bug, not load. The driver writes that line in pieces, and the stderr ingress keeps each read as
  whole lines. When the reader wakes between the pieces, the line splits in two. See
  `spec/bugs/20261117-stderr-line-split-across-reads-shows-as-two-lines.md`.
- Fix: the stderr ingress joins a partial line with the next read, and lets a lone one go after 250 ms of quiet. The
  fixture driver writes each line in one piece, so the test does not depend on that period. A unit test that offers a
  line in two pieces failed before the fix with two lines. A channel test with the tail check turned off timed out.

### `TerminalSessionIntegrationTests.testAPendingClipboardAnswerIsStaleAfterAPolicyChangeOrAClose`

Fixed by: "Give terminal sessions their clipboard, so tests use a private one"

- Seen: 2026-11-15, once, in a local `make test-package` run during a work-queue run that touches no terminal code.
- Evidence: the test asserted that the system pasteboard held `SECRET-STALE`. It held text another session had just
  written to it. The test passed alone, and the next full run passed.
- Cause: the terminal surface read and wrote `NSPasteboard.general`, and so did the tests. Any other program that
  copied mid-run changed what the test saw. The product's clipboard policy was right.
- Fix: the terminal engine takes the pasteboard its sessions use, and the app passes the system's. The integration
  tests make their own with `NSPasteboard.withUniqueName()`, so they no longer save and restore the user's clipboard.
  A thread that wrote the system pasteboard every 50 ms failed the old test with "a stale write landed". The fixed
  test passed with the same thread running.

### `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread`, now `testATextSearchNeverRunsOnTheMainActor`

Fixed by: "Prove the text search runs off the main actor with a gate, not a turn count"

- Seen: about ten times between 2026-11-14 and 2026-11-17, in CI and in local full `make test-package` runs. It counted
  3 to 82 main-actor turns where it expected more than 100. It passed alone each time.
- Evidence: the search ran off the main actor all along. `FindMatching.searchOffMain` is `@concurrent`. Earlier test
  classes that warmed Foundation's case-insensitive tables shifted the count, so the count tracked timing.
- Cause: the test counted `Task.yield()` turns while the search ran. That measured how long the search took and how
  busy the main actor was, not where the search ran. The product was right.
- Fix: the pane's text search is now a `@concurrent` function property, so nothing assigned to it can run on the main
  actor. The test assigns one that waits at a gate, and the main actor opens the gate only after it sees the search in
  flight. A coordinator made to search inline on the main actor fails it, with "the search never reached the pane's
  searcher". The test now searches a short document. Laying out four million characters could hold the main actor
  long enough that the gate gives up, and the gate proof does not need the size.

### `LaunchOpenCoordinatorTests`, the batch and refused-package tests

Fixed by: "Wait for the launch-open coordinator's drain instead of yielding a fixed number of times"

- Seen: 2026-11-14 and 2026-11-15, once each, in CI's package job on branches that do not touch the launch-open code.
- Evidence: `testABatchOpensOnePanePerFileAndSummarizesFailures` saw 0 of 2 folder panes open, and no failure
  message. `testAPackageIsRefusedThroughTheLaunchServicesPath` found no failure message for the refused bundle.
- Cause: the fixture's `settle()` yielded the main actor 50 times. The router finds each path's type off the main
  thread, so yielding never waited for it, and a slow runner asserted first. Tests that check that nothing happened,
  such as `testAFailedWarmOpenWithNoWindowOpensNoShell`, passed without proof the same way. `LaunchOpenApprovalTests`
  had the same flaw, with up to 20,000 yields. The coordinator itself was right.
- Fix: the coordinator keeps its drain task, and `idle()` waits for it to end. Both fixtures' `settle()` await it.
  `testASenderThatAlreadyExitedTouchesNothing` had used `settle()` to let its watcher's end report run, so it now awaits
  that task. A 300 ms sleep in the coordinator fixture's type lookup failed three coordinator tests with the CI symptom,
  then crashed the run with an index out of range. After the fix, the coordinator class passed with the sleep in
  place. The approval fixture has no such hook, so a denial made to open its files checked those tests instead. Three
  failed, so they do not pass by default.

### `ScriptReplTests.testRestoredHistoryIsNeverEvaluated`

Fixed by: "Wait for the REPL's line event before checking what the restored history did"

- Seen: 2026-11-15, once, in the first CI `package` run of PR #53, which does not touch the REPL.
- Evidence: `ScriptReplTests.swift:554` found `events.lines` empty where `["(+ 20 22)"]` was expected. The test
  passed 20 of 20 alone, and the rerun passed.
- Cause: the test read `events.lines` as soon as `42` showed on the pty. The `.line` event comes over the host's
  socket, a separate path, so it can arrive after the output. The REPL itself was right.
- Fix: the test waits until the socket reports the typed line and the end of its evaluation. The socket keeps its
  order, so a restored line that ran would be reported before that. Delaying every event in the test's recorder by
  300 ms failed the old test with the CI message, and the fixed test passed with the same delay.

### `ExecPaneTests.testAStalledDriverNeverHoldsTheMainThread`

Fixed by: "Measure the stalled-driver flood against the same clicks with no driver"

- Seen: 2026-11-15, twice, in both CI `package` runs of PR #49, at 5.47 s and 8.62 s against a 5 s bound.
- Evidence: locally the 20,000 clicks took 1.61 s with no driver and 1.72 s with the stalled one. The main thread's
  turn came 11 ms after the flood.
- Cause: the bound timed the clicks themselves, which AppKit makes cost about 80 µs each. A CI runner is several times
  slower. The driver was right.
- Fix: the test times the same clicks with no driver first, and the flood must cost less than twice that. A send made
  to sleep 200 µs fails it, at 9.8 s against 3.2 s.

### `FileWatcherTests.testChangesToOtherFilesInTheFolderDeliverNothing`

Fixed by: "Assert that a folder watch notes no neighbor's change, not one note per write"

- Seen: 2026-11-14, four times in CI's package job, in the text viewer PR and the Janet scripting PR.
- Evidence: `FileWatcherTests.swift:112` counted 2 notes where it expects 1. The test passed 10 of 10 alone.
- Cause: the test expected exactly one note for the file's own write, and a write can make two. A folder event from the
  neighbor churn can be handled after the write, so it sees the file changed. The in-place write can also raise two file
  events. The coalescer merges them, so the viewer still reloads once. The watcher itself was right.
- Fix: the test drains the watcher's queue after the churn and asserts that the churn made no note. Then it asserts the
  write made at least one. A watcher made to note every folder event fails it, with 3 churn notes. After the fix, the
  file watching tests passed 30 of 30 alone.

### `BrowserRecoveryTests.testKillingTheSelectedTabShowsTheMessageAndReloadBringsBackItsHistory`

Fixed by: "Wait for the reloaded title in the browser recovery test"

- Seen: 2026-11-07.
- Evidence: it failed once in a full `make test-package` run. Run alone, it failed 1 of 3 times. The failure read
  "127.0.0.1" where "B" was expected. A later series of 12 isolated runs did not reproduce it, so the rate there is 0 of
  12 before the fix and 0 of 7 after.
- Cause: the test waited for the reloaded page to finish loading, then read the tab title once. Reload builds a new web
  view with no title. WebKit reports the page title a moment after the load ends. Until then the tab shows the host,
  which is `127.0.0.1` on the fixture server. The product is right to show the host while the title is unknown. The
  race is in the test, which had no signal that the title had arrived.
- Fix: the wait that follows Reload now includes the title, so the assertion runs after the title has arrived.

### `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile`

Fixed by: "Wait for the app to be frontmost before UI tests type, and paste open-panel paths"

- Evidence: alone, it failed 1 of 6 at `waitForExistence` on the launcher after Cmd-D. The key never took effect.
- Evidence: in a full suite, it failed at the go-to field check. The typed temp path had become a neighbouring
  container's path. The `dev.uniterm.app.UITests.xctrunner` component turned into `dev.uniterm.UITests.xctrunner`.
- Cause of the first failure: the test sent Cmd-D before the app was frontmost. A synthesized key event goes nowhere
  then. The app never deactivates itself, so the race is in the test.
- Cause of the second failure: the open panel's go-to field autocompletes each path component while text is typed.
  Sibling folders that share a prefix make that rewrite the path.
- Fix: `waitForTerminal` now waits for the app to be frontmost, and activates it once if it is not. The test pastes
  the path instead of typing it, so the field has no keystrokes to autocomplete. It still checks the field's value.

### `WindowsUITests.testCommandWClosesOnlyTheKeyWindow`

Fixed by: "Wait for the app to be frontmost before UI tests type, and paste open-panel paths"

- Evidence: alone, it failed 1 of 6 at the foreground assertion after Cmd-W. The app state read `runningBackground`.
- Evidence: in a full suite, it failed because `echo "K:$((6*7)):"` never produced output in 20 s after a click on the
  first window.
- Cause: the state read right after a window close can lag. The test read it once. Keys sent while the app was still in
  the background went nowhere. The product has no code that hides or deactivates the app.
- Fix: the foreground assertion now waits for the state to settle, without activating the app. The same wait replaces
  the one-shot read in `testClosingTheLastWindowKeepsTheAppRunningAndCommandNOpensAgain`. `waitForTerminal` activates
  the app before the first key.

### `ImageViewerScrollTests.testScrollMovesTheImageTheWayAScrollViewMovesItsDocument`

Fixed by: "Wait for the reference scroll view to move in the image viewer scroll test"

- Seen: 2026-11-08, once in CI on a PR that changed no image viewer code.
- Evidence: the first case, a precise scroll of 0,40, failed "no oracle". The reference scroll view had not moved, so
  the test also read the image's correct pan as wrong. Run alone, it failed 1 of 20 before the fix.
- Cause: a fresh scroll view applies its first scroll on a later run loop pass, not inside `scrollWheel(with:)`. The
  test ran the run loop for a fixed 0.05 s and then read the scroll view once. Under load, that pass had not run yet.
  With no wait at all, the test failed every time, on that first case only. The image viewer itself was right.
- Fix: the test now runs the run loop until the scroll view leaves its starting point, with a two-second bound. A scroll
  view that never moves still fails the "no oracle" check. After the fix, it passed 20 of 20 alone.
