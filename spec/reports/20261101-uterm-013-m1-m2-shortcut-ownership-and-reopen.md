# UTERM-013 M1-M2: Shortcut ownership and reopen work-queue run

Started 2026-11-02. This report covers the second row of a `/work-queue next 2` run: `UTERM-013 M1-M2`, at
`spec/proposals/UTERM-013-shortcut-ownership-and-reopen.md`. UTERM-013 moves applet shortcuts to the applets, reserves
uniterm's window keys, and adds Cmd-Shift-T to reopen the newest closed tab or pane. The run state and the run-level
best guesses are in [20261101-uterm-002-m1-m3-command-palette.md](20261101-uterm-002-m1-m3-command-palette.md). The
specs live in the code repo, so every commit below is in this repo, on `main`.

## TL;DR

The row finished on 2026-11-02, and UTERM-013 is `implemented`. M1 moved terminal shortcuts to the terminal, built
menus from the command registry, and reserved uniterm's window keys. M2 added Cmd-Shift-T to reopen the newest closed
tab or pane, and made Cmd-Z undo text edits only. One full UI run during M2 failed 5 tests that passed in two later full
runs, with the cause unresolved.

## Row base

The row starts at "Finish the command palette", the commit that finished UTERM-002. UTERM-013's dependency on UTERM-002
M1 is met.

## Milestones

### UTERM-013 M1: Applet-declared shortcuts

Commit: "Let applets declare their own shortcuts and reserve uniterm's window keys".

Checks, final round: `make fmt-check`, `make lint`, and `make check` pass. `make test-package` ran 521 tests, with 4
skipped and 0 failures. `make test-app` passed in 565 seconds. `proposals.py check` and `proposals.py freeze` report
nothing.

Test cost: the new unit test files run in under a second together. `ShortcutOwnershipUITests` adds a few UI tests of a
few seconds each.

Best guesses by the implementer:

- Menu building moved from the App target into WindowKit. Menu items carry their command ID, so each command is now
  declared once, and the per-command adapters are gone. The hand-built menu file is deleted.
- Applets register a command set with IDs namespaced by applet type, such as `terminal.clear`. The terminal's old
  `uniterm.*` IDs for tabs, text size, and clear are retired, not reused. Recency is in memory only, so nothing stored
  names them.
- A command's action receives its applet at run time and keeps no reference to it.
- The reserved set is read from the live menu: every item that is not an applet's, plus the fixed Edit keys. That
  covers the keys AppKit adds itself without a table. The set is re-read at install, on a defaults change, on app
  activation, and before every routed Command-key press. The press-time read is the guarantee, since AppKit's timing
  for applying a remap is undocumented.
- The key route tries a remapped item first, then uniterm's items, then applet items. A disabled remapped or uniterm
  item consumes the key. A disabled applet item lets it fall through. Two remaps on one key resolve by menu-bar order.
- Cmd-1 to Cmd-9 still reach the launcher, because the terminal's tab items are hidden while a launcher has focus.
  The launcher's special first offer in the key route is gone.
- File > Close also closes a non-main key window such as Settings, and never a sheet. The Settings window's own close
  handler was removed.
- An agreed close of a running tab that has become the last tab answers "nothing to close", so the pane close guard
  asks again.
- The palette keeps "Close Tab or Pane" as its entry title. The menu item is "Close".

Amendments, each with a Decision Log entry giving the prior meaning: "What one shortcut declaration is", "Which keys
uniterm reserves", "Who decides what Cmd-W closes", the launcher's first offer of Cmd-1 to Cmd-9, and "What happens on a
key conflict".

Residuals: the test cannot assert that a closed pane's applet is freed, since the window keeps references for a while.
It pins that a command aimed at a closed pane reaches nothing. The Settings window has no editable text field, so the
check about Settings rows has nothing to act on. Cut is disabled in the terminal.

UTERM-002's As built describes the shapes M1 replaced, such as the text-action protocol and the launcher's first
offer. Those were true when UTERM-002 shipped, so they are not corrections of fact, and UTERM-002 stays frozen.

Review findings:

- ADR-04 says the user is told when an applet loses a key. A key dropped after the applet type's first warning was
  silent. The ADR review called this a plausible conflict, and the reviewer flagged the same gap. Fixed: each check of
  the reserved set posts at most one warning per applet type, naming only drops not announced before. "What happens on a
  key conflict" and two M1 checks were amended to match.
- The Decision Log entry gave only the new rules: fixed, one entry per amendment with its prior meaning.
- The edit-actions check was tested only on the launcher field: fixed with a menu test of the edit selectors.
- Two remaps on one key had no direct test: fixed with a unit test through a remap seam.
- A test polled with real sleeps: fixed with a direct signal from the test host.
- A doc comment sat on the wrong declaration: fixed.

ADR review: one plausible ADR-04 conflict, fixed as above. Its candidates are already settled. The namespaced command
ID candidate waits on UTERM-003, per the Decision Log. The key route is mechanism the proposal keeps out of ADR-04. The
title-as-remap-contract rule is a UTERM-002 risk that shapes only the menu.

### UTERM-013 M2: Reopen with Cmd-Shift-T

Commit: "Reopen the newest closed tab or pane with Cmd-Shift-T".

Checks: `make fmt-check`, `make lint`, and `make check` pass. `make test-package` passes with 0 failures. `make
test-app` ran three full times outside the sandbox. The first run had 5 failures out of 77. The next two passed 77 of
77, confirmed from their result bundles with `xcrun xcresulttool get test-results summary`. `proposals.py freeze`
reports nothing. `proposals.py check` reports only the row-finishing steps.

Unowned failure, diagnosis unresolved: the first full run failed these 5 tests:

- `CommandPaletteUITests.testChoosingABackgroundTabSelectsItAndTheKeyboardFollows`
- `TabsUITests.testNewTabsShowTheBarAndEachRunsItsOwnShell`
- `TabsUITests.testProgramModeHasNoNewTab`
- `TerminalUITests.testClearScreenClearsTheTerminal`
- `TerminalUITests.testCommandKeysReachUnitermWhileTheTerminalIsFocused`

Three of them timed out after about 40 seconds waiting for a shell prompt or terminal text. That run took 676 seconds,
against 568 for the clean runs. The class reruns and two full reruns in the original order all passed. The tests were
not run on the previous commit. One hypothesis: the implementer's first `make test-app` attempt through cg timed out
enabling automation, and it may have overlapped the failing run, so two UI suites fought over the GUI session. A
passing rerun does not prove a fix, so this stays open.

Test cost: `ReopenClosedTests` runs 9 tests in 0.26 seconds. `TerminalReopenTests` runs 9 tests in about 0.01 seconds.

Best guesses by the implementer:

- The window command is `uniterm.reopen-closed`, titled "Reopen Closed Tab or Pane" in File beside Close, on
  Cmd-Shift-T. The title is fixed so App Shortcuts remaps keep matching. It is disabled when nothing is reopenable, and
  the reserved key route consumes the key.
- A failed tab reopen reports a title and a reason, since the window keeps no copy of the applet's list.
- The closed-tab list depth is 20, matching the pane undo depth.
- The undo-only part of a description is stripped before the layout is saved and before the layout-change compare.
- The Edit menu's Undo item is disabled outside a text edit. The empty-undo status message is gone, so two UI tests
  that read it now post through a debug hook instead.
- No hidden inheritance was found. A reopened tab's directory flows through its closed-tab description.

Amendments, each with a Decision Log entry giving the prior meaning: "Applets own their tabs, and reopening them",
"Cmd-Shift-T reopens, and Cmd-Z undoes text edits only", and the closed-tab depth.

Residual: no controller test covers an older pane reopened past a newer pane that does not fit, since no layout makes
only the newer pane fail. A tab failure covers the same removal path, and a ledger unit test pins remove-by-stamp.

Review findings: none.

ADR review: no conflicts. Advisories on naming only. ADR-03's rationale and ADR-04's context still say Cmd-Z gets a
closed pane back, and ADR-05 calls the action "undo". Their decisions still hold. An accepted ADR takes only minor
edits, so these are left for the user. Of the candidates, in-memory-only undo state was declined on 2026-11-01, and
host-stamped closes across applets waits on UTERM-005 to UTERM-010, per the Decision Log. The Cmd-Z-for-text-only
policy is a key binding choice inside UTERM-013 and does not pass the ADR bar.

UTERM-001's text says Cmd-Z reopens a closed pane, and UTERM-002 refers to it. UTERM-013 supersedes that part. The row
finish adds a "Superseded in part by UTERM-013" marker to UTERM-001, which the freeze allows.

### UTERM-013 row review

The review covered both milestone commits together. It found no correctness or security defect, and judged the applet
contract coherent and minimal for the later applets.

Findings and dispositions:

- "Who decides what Cmd-W closes" kept an old marker, and the last-tab rule lived only in the log: fixed. Both 2026-11-02
  rules are now in the decision text.
- The menu placement bullet's marker had moved to a date with no matching entry: fixed.
- M1's As built said Cmd-Z keeps its behavior, which M2 made false: fixed.
- The proposal said Edit > Undo keeps the title "Undo", but AppKit retitles it while a field is edited: fixed by
  amendment. Whether an App Shortcuts remap of "Undo" still matches while the item reads "Undo Typing" is unverified.
  The Decision Log entry says so.
- The pane undo ledger's `newest` property had no production reader after M2: removed.
- A palette test still named the removed text-action protocol: renamed.
- Uniform marker date formats: dismissed, since `proposals.md` says a later revision replaces the marker.

Fix commit: "Tidy shortcut ownership after review". Checks: `make fmt-check`, `make lint`, `make check`, and `make
test-package` pass. The code changes were a dead property and a test name, so `make test-app` did not rerun.

UTERM-002 text that UTERM-013 changed later, such as the text-action protocol, the launcher's first offer of Cmd-1 to
Cmd-9, and the uncanonical key match, describes what UTERM-002 shipped. It is not a correction of fact.

ADR review over the row: no conflicts and nothing new. Its candidates are settled or deferred in the Decision Log.

Row finish commit: "Finish shortcut ownership and reopen". UTERM-013 is `implemented`, the index says so, and its row
moved to `history.md`. UTERM-001's M7 and M10 carry "Superseded in part by UTERM-013", with a Decision Log entry, since
they bound pane reopen to Cmd-Z. `proposals.py check` and `proposals.py freeze` report nothing.

## Status

Done. The run's final review is in the first row's report. Nothing was pushed.
