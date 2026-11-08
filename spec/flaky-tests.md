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
- Status: unresolved.

### `PaneTreeUITests.testFocusMovesWithTheKeyboardAndInputReachesOnlyTheFocusedPane`

- Seen: 2026-11-07, once in a full suite.
- Evidence: `PaneTreeUITests.swift:59` failed. The typed `echo "L:$((6*7)):"` never showed in the focused pane within
  20 s. The test passed 3 of 3 alone.
- Suspected cause: keys sent right after Cmd-Option-Left moved focus went nowhere. This is the same pattern as the fixed
  Cmd-W flake.
- Status: unresolved.

### `PaneTreeUITests.testReopenBringsBackTheClosedPaneFromItsDescription`

- Seen: 2026-11-07, once in a full suite, in the same run as the entry above.
- Evidence: `UnitermUITestCase.swift:142` found no `pane-2`. The test passed 3 of 3 alone.
- Suspected cause: the pane-opening key went nowhere, as in the entry above.
- Status: unresolved.

## Fixed

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
