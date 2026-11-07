# UTERM-001 M1-M9: Foundation work-queue run

Started 2026-10-31. This report covers a `/work-queue` run of the queue row `UTERM-001 M1-M9`. UTERM-001 is
uniterm's foundation proposal, at `spec/proposals/UTERM-001-foundation.md`. The specs live in the code repo, so every
commit below is in this repo. The branch is `agent/petunia/uterm-001`.

## TL;DR

The run finished on 2026-11-01. M1 to M8 are done, each in its own commit, followed by a row-review fix commit and a
final-review fix commit. The last full runs were `make test-package` with 380 tests, 0 failures, and 4 US-layout skips,
and `make test-app` with 46 UI tests and 0 failures. M9 was held for the user's visual check. A second run on
2026-11-01 recorded it. The row is now in `history.md`, and UTERM-001 is `implemented`.

For the user:
- After the run, the user ruled that undo reopens a pane from its description and is not a snapshot of running
  processes. M10 removed the keep-alive tier. See "Follow-up after the run" below.
- OSC 52 clipboard writes are allowed without asking, and only reads ask. The unreachable write dialog was removed.
- An unavailable layout folder opens one window that saves nothing, instead of quitting.
- After the run, ADR-05 and ADR-06 were written. The other candidates are listed in "ADR candidates" below.

The session was interrupted during M7. A new coordinator session resumed it from this report, the state file, and git.

## Run state

- Base commit for the run and for the row: "Merge pull request #2 from space-armada/agent/uterm-spec/accept". The
  branch was rebased onto it after M4, and the tree was unchanged.
- Specs commits: the specs live in the code repo, so the milestone commits are the specs commits

| Milestone | Run status | Commit |
|-----------|------------|--------|
| M1 App skeleton and theme tokens | DONE | "Add the app skeleton, pinned Ghostty build, and theme tokens" |
| M2 Terminal applet in a single pane | DONE | "Add the terminal applet behind a libghostty surface protocol" |
| M3 Pane tree | DONE | "Add the normalized pane tree with splits, dividers, and focus" |
| M4 Status bar region | DONE | "Add the status bar region with docking, segments, and message history" |
| M5 Terminal tabs and program mode | DONE | "Add terminal tabs and program mode" |
| M6 Multiple windows | DONE | "Add multiple windows with per-window panes and status" |
| M7 Undo close pane | DONE | "Add undo close pane with grace and description tiers and close guards" |
| M8 Layout persistence | DONE | "Save and restore every window's layout across launches" |
| M9 User visual check | DONE, in a second run | This report's own commit |
| Row review fixes | DONE | "Fix undo order, placeholder undo, and background-tab saves found in review" |
| Final review fixes | DONE | "Ask once and settle pane exits during close questions" |

Held or blocked rows: none.

## Environment

- macOS 26.6.2 (25G83), Xcode 26.6 (17F113), SDK 26.5, Swift 6.3.3, Zig 0.15.2 from Homebrew
- Ghostty pin: tag v1.3.1, peeled commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. `build.zig.zon` declares
  `minimum_zig_version = "0.15.2"`

## Run-level best guesses

These come from the approved plan at `~/.claude/plans/harmonic-herding-dewdrop.md`.

- Pin Ghostty v1.3.1. Fall back to v1.3.0 (`703d11c6`) if it does not build with Xcode 26.6.
- Swift 6 language mode with strict concurrency, in both the package and the app.
- M2 builds the full status message model. M4 renders it.
- Formatter and linter: `swift format` from the toolchain.
- Tunable bounds get concrete values chosen by the implementer and recorded in As built.
- M9 is left to the user.

## Milestones

### M1: App skeleton and theme tokens

Commit: "Add the app skeleton, pinned Ghostty build, and theme tokens".

Checks:
- `make fmt-check`, `make lint`, `make check`, `make build`, and `make test` all pass. `make test` ran 12 package
  tests and 3 UI tests. `make ghostty-offline-check` passes, and `make ci` now runs it.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- `xcrun`, `swift`, and `xcodebuild` fail in the Bash sandbox with "couldn't create cache file", so every check ran
  unsandboxed.

Best guesses from the implementer:
- Zig 0.15.2 cannot link against the macOS 26 SDK. The SDK's libSystem stub lists only `arm64e`.
  - The build puts an `xcrun` shim on Zig's PATH. It answers `--show-sdk-path` with the Command Line Tools SDK
    `MacOSX15.4.sdk`, and passes every other query through.
  - The pin records `ZIG_SDK_VERSION=15.4`.
  - If this is wrong, a machine without that Command Line Tools SDK cannot build Ghostty. A Zig bump would remove the
    shim.
- Xcode 26.6's `libtool` silently drops Zig's archive members. A `libtool` shim extracts each input archive and
  combines the loose objects. It fails when the member count and the extracted count differ.
- Ghostty's build needs the Metal toolchain component. The implementer ran `xcodebuild -downloadComponent
  MetalToolchain`, a 688 MB system-wide install outside the repo. The README lists it as a prerequisite.
- The Ghostty source is a codeload tarball fetched by commit. A tree hash, `GHOSTTY_TREE_SHA256` in `ghostty.pin`,
  verifies the extracted files. `scripts/build-ghostty.sh tree-hash` computes it on a pin bump.
- The bundle ID is `dev.uniterm.app`, since the project names no owner domain.
- The modules are Theme, Preferences, WindowKit, SettingsKit, and TerminalSurface. The settings types are named
  `SettingKey` and `SettingsStore`, since SwiftUI owns `PreferenceKey`.
- `Package.swift` calls `fatalError` naming `make build` when the xcframework link is missing.
- The UI tests isolate preferences through `UNITERM_DEFAULTS_PATH`.
- The deinits use `isolated deinit`, which is Swift 6.2 syntax.

Deviations:
- Hardened runtime is set, but Xcode ignores it under ad hoc signing.
- No UI test can prove the chrome reacts to an out-of-process `defaults write`. The UI test runner is sandboxed, and
  its writes never notify the app. `swift test` covers the store's reaction to a real `defaults` child process. The
  window's reaction was checked by hand on a launched binary.

Review findings, all fixed:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | The tarball had no integrity check | Trace confirmed, fixed with a tree hash |
| 2 | Stale-lock takeover race | Trace confirmed, replaced with a kernel `flock` |
| 3 | No evidence for the relink check or the interrupted-build check | Fixed. Both demonstrated, see As built |
| 4 | The offline check was outside `make ci`, and SIGINT could delete the artifact | Fixed. Tested with SIGINT |
| 5 | UI tests wrote real preferences | Confirmed, fixed |
| 6 | No automated test of an external `defaults write` | Recorded as a gap. The runner's sandbox prevents it |
| 7 | Duplicate archive member names in the libtool shim | Not confirmed in practice. A guard was added. Diagnosis unresolved |
| 8 | Misplaced comment | Fixed |
| 9 | `watch(_:)` was not idempotent | Confirmed by a failing test first, then fixed |

adr-impact: no conflicts and no supersessions. It found no uncovered decision that meets the ADR bar.

Checks left to the user:
- Flip the system appearance while the setting is System, and confirm the chrome follows.
- Open the project in the Xcode UI on a cold checkout, and confirm the error names `make build`.
- Confirm the "no GUI or no Accessibility" message of `make test`. It never fired here, since the UI tests ran.

Test cost: `swift test` 0.4 s of test time, UI tests 15.6 s, `make test` about 24 s. A cold Ghostty build and the
offline rebuild take about 4 minutes each. The Zig cache is 483 MB.

Leftovers: a hook blocked the implementer's `rm -r`. The git-ignored `.cache/scratch`, `.cache/ghostty-src`, and
`.cache/ghostty/lock` are dead and can be deleted by hand.

### M2: Terminal applet in a single pane

Commit: "Add the terminal applet behind a libghostty surface protocol".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package`, and all
  passed.
- The coordinator reran `make test-package` independently: 100 tests, 0 failures, 4 skipped. The 4 skips are the
  key-translation tests that assert US-layout codepoints. The user's layout is US Extended.
- The coordinator ran the UI suite once on a quiet desktop with `make test-app`: 11 tests, 0 failures, 52 s. The screen
  captured by the resize test showed `A:34x119:` before the resize and `B:25x82:` after it.
- The user typed `echo 'a' "b"` on a real keyboard in the built app and saw `a b`.
- `proposals.py check` and `proposals.py freeze` both print `[]`.

Best guesses from the implementer:
- The new modules are StatusKit, AppletKit, and TerminalApplet. The protocols are `TerminalEngine` and
  `TerminalSession`.
- libghostty's C API surfaces only the OSC 133 command-finished mark. The protocol carries a `commandFinished` event,
  plus a running-state query that follows the prompt marks. The proposal's protocol decision and one M2 check were
  amended to match. ADR-01 says "prompt marks", and adr-impact judged it consistent. ADR-01 was not edited.
- The config builder rejects unsafe values instead of escaping them. It uses an allow list of keys and a safe value
  alphabet.
- The config file is per instance, at `~/Library/Application Support/uniterm/terminal/ghostty-<pid>.conf`. Stale files
  from dead pids are removed at engine start.
- The C callbacks hop to the main actor asynchronously. A surface freed inside its own close callback would be a use
  after free.
- The clipboard alert names the pane, with Cancel as the default. A denial completes with empty data.
- The status bounds are a 1.5 s dwell, a 5 s idle timeout, a skip above a backlog of 3, and a history of 500.
- Cmd-T, Cmd-D, and Cmd-Z post "not available yet" until their milestones land.
- `UNITERM_TERMINAL_DIR` is honored only in DEBUG builds.

Deviations: none beyond the amendment above. The close guard is M7's, so Cmd-W and Cmd-Q do not ask yet.

Review findings, first round:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | `WindowChromeUITests` ran the developer's real shell | Fixed with a shared launch helper |
| 2 | Cmd-W no longer closed Settings, a regression from M1 | Fixed. A unit test fails without the fix |
| 3 | UI flakes, with a suspected main-thread hang on close | Hang not confirmed. Diagnosis unresolved. Teardown and activation added |
| 4 | The palette test passed vacuously | Fixed. It fails when the update call is removed |
| 5 | The vim test never confirmed vim was up | Fixed |
| 6 | The apostrophe cause was unproven, and the real key path was untested | Fixed. A real key-path test and a user check were added |
| 7 | Amendment markers were missing, and As built held a path list | Fixed |
| 8 | A milestone name in a code comment, and a dense test doc | Fixed |
| 9 | No evidence for the sandbox and `$HOME` check or the menu path | Fixed |
| 10 | The ssh probe read `~/.ssh/config` | Fixed with `-F /dev/null` |
| 11 | Minor config-store and test-comment items | Fixed |

User-raised issues during M2:
- The UI test typed `'`, which arrived as `;5u`. XCUITest delivered the key with the Control flag (`flags=262144`).
  The real key path is correct, and the user confirmed it on a real keyboard. Why XCUITest adds Control on US Extended
  is unresolved.
- Tests that spawned a shell ran the user's dotfiles and prompted for an SSH passphrase. Every shell a test spawns is
  now isolated.

adr-impact: no conflicts and no supersessions. Two ADR candidates were recorded as Undecided in the proposal's Decision
Log: the applet contract, and the clipboard-read confirmation policy.

Checks left to the user:
- One real ssh session to a host without the `xterm-ghostty` terminfo entry.
- A live system appearance change reaching the terminal palette.
- The on-screen colors after a palette change.

Process notes:
- The implementer ran `git checkout App/AppDelegate.swift` mid-work, which discarded its own edits. It rewrote the
  file, and the reviewer found it coherent.
- Debug runs left 15 orphaned `sleep 1000` processes. They exit on their own after about 17 minutes.

Test cost: `swift test` takes 7.4 s of test time for 100 tests. The UI suite takes 52 s.

### M3: Pane tree

Commit: "Add the normalized pane tree with splits, dividers, and focus".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, a build of the UI test target, and
  `make test-package`, and all passed.
- The coordinator reran `make test-package` independently: 145 tests, 0 failures, and the same 4 US-layout skips.
- The coordinator ran the UI suite with `make test-app`. The first run had 21 tests and 3 failures. All 3 waited on
  `pane-3`, but the allocator gives the first split pane 2 and split 3, so the second new pane is pane 4. The tests now
  wait on the pane count and order. The rerun had 21 tests, 0 failures, and took 152 s.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- The implementer mutation-checked 14 model and controller rules. Each mutation failed a named test. One mutation first
  passed, because the focus-marker logic was duplicated. That logic was merged, and the mutation then failed.

Best guesses from the implementer:
- Axes are named `row` and `column`. "Split Right" is Cmd-D and "Split Down" is Cmd-Shift-D, following Ghostty and
  iTerm2.
- The minimum pane size is 200 by 100 points, and a divider is 5 points thick.
- Closing a pane gives half its weight to each adjacent sibling, or all of it to a single neighbor. Focus goes to the
  nearest pane only when the closed pane had focus.
- A split is refused when either new pane would fall below the minimum, or when the resulting tree's minimum exceeds the
  current size. A refusal burns no ID.
- The window minimum follows the tree. The old 480 by 320 floor is gone.
- Every split opens the applet picker, and Return accepts the terminal in shell mode. Program mode collects a command
  but refuses to open until M5.
- Cmd-] and Cmd-[ move focus in reading order, and Cmd-Option-arrow moves it by direction. While a sheet is up, the pane
  actions are disabled. Escape cancels the picker, and Cmd-W does not.
- Focus follows the window's first responder on `NSWindow.didUpdate`.

Deviations: the merge check was amended. Divider thickness makes exact sizes impossible, so a merged pane may shift by
c·(m−1)·(1−w)·d, which is under (m−1) divider thicknesses. Sizes stay exact with zero thickness.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | Focus jumped when an unfocused pane's applet exited | Confirmed by a failing test, fixed |
| 2 | A reused applet identity could skip `start()` | Confirmed as a design bug by a failing test, fixed |
| 3 | The amended merge bound was wrong for 3 or more children | Wording fixed. A test checks the hand-computed shifts |
| 4 | A split could squeeze siblings below the minimum | The reviewer's example was not a bug. A different case was, and it was fixed with a failing test first |
| 5 | Menu actions stayed live under the picker sheet | Confirmed by a failing test, fixed |
| 6 | No test that vertical focus keys reach uniterm from a focused terminal | UI test added |
| 7-10 | Test comment numbers, a duplicate test, a UI wait, comment craft | Fixed |

adr-impact: no conflicts and no supersessions. Restoring a layout must reseed the ID allocator from its saved high-water
mark. That is for M8.

Checks left to the user: the focus ring's and the dividers' look on screen, the resize cursor, and a real mouse drag of a
divider.

Test cost: `swift test` takes 8.0 s of test time for 145 tests. The 25 pane-model tests take 0.004 s.

### M4: Status bar region

Commit: "Add the status bar region with docking, segments, and message history".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, `make test-package`, and a build of
  the UI test target, and all passed.
- The coordinator reran `make test-package` independently: 191 tests, 0 failures, and the same 4 US-layout skips.
- The coordinator ran the UI suite. The first run had 24 tests and 1 failure. The unseen-error test queried
  `window.images`, but XCUITest exposes the icon-only segment as a plain element. The failed run's accessibility
  hierarchy showed the indicator present with a 15 by 10 size. The rerun had 26 tests, 0 failures, and took 187 s.
- `proposals.py check` and `proposals.py freeze` both print `[]`.

Best guesses from the implementer:
- The bar docks at the bottom by default, from one global `statusBarPosition` setting with values `top` and `bottom`.
- The region model is a role, a dock edge, and an inward stacking order. A later region joins by adding a role and a
  view.
- History is a floating 240 pt panel that grows away from the bar. The proposal's "expand" wording was amended to say
  so. Clicking the bar or pressing Cmd-Shift-M toggles it.
- Closing a pane drops its queued messages. The message already on the bar finishes its turn. Folded errors from other
  panes are queued again.
- The terminal applet's segments are the working directory and a failing exit code.
- The segments are AppKit views.
- An invalid dock position warns once per distinct bad value, and a valid value resets the rule.
- Dismissing an error uses a "Dismiss Message" menu item (Cmd-Option-Delete) or a close glyph on the error. Both are
  live only while an error shows. Dismissing does not clear the unseen-error indicator.
- UI tests get an error from a DEBUG-only launch variable, since the program-mode refusal goes away in M5.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | Dismissing an error was settled but not built | Built, as a run best guess |
| 2 | Closing a pane could lose other panes' folded errors | Confirmed by a failing test, fixed |
| 3 | The proposal said "expand", but the code shows a floating panel | Text amended in place |
| 4 | "Warns once per distinct value" was untested | Tests added and mutation-checked |
| 5 | The error UI test depended on the program-mode refusal | Replaced by a DEBUG-only hook |
| 6 | Real sleeps in tests, and a duplicate process test | Sleeps removed. Both process tests kept, with their distinct jobs stated |
| 7-9 | As built shape, test doc comments, a dead region case | Fixed |

adr-impact: no conflicts and no supersessions. The implementer's region-model candidate fails the ADR bar, since it is
one component's internals.

Checks left to the user: the bar's look at each edge, the empty band under the title bar when docked on top, the history
panel on screen, and the Cmd-Shift-M binding.

Process note: the implementer waited 15 minutes on cg's allowlist for `xcrun xcresulttool`. The user added it to
`.cg.yaml`, and later added `codesign -d` and `plutil -p`.

Test cost: `swift test` takes 10.5 s of test time for 191 tests. The UI suite takes 187 s for 26 tests.

### M5: Terminal tabs and program mode

Commit: "Add terminal tabs and program mode".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, a build of the UI test target, and
  `make test-package`, and all passed.
- The coordinator reran `make test-package` independently: 220 tests, 0 failures, and the same 4 US-layout skips.
- The coordinator ran the UI suite once: 31 tests, 0 failures, 231 s. The review fixes that followed changed only
  comments, the proposal, and package tests.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- The implementer mutation-checked 9 behaviors: the ssh TERM match, Cmd-W taking a tab first, closing the selected tab,
  the guard both ways, the tab bar at one tab, program mode with no new tab, the inert program description, and the
  any-tab running rule. Each mutation failed a named test.

Restarts: three implementers worked on M5.
- The first sat 50 minutes on a cg prompt for `pgrep`, which was not on the allowlist. The coordinator stopped it after
  its code was written and before its checks ran.
- The second sat 30 minutes on a cg prompt for a mutation script in the scratchpad. The coordinator stopped it after
  every local check had passed.
- The third was briefed with the exact list of allowed commands. It finished the mutation checks and the proposal.
- The coordinator confirmed that neither stop left a mutated source file or stray processes.

Best guesses from the implementers:
- A program-mode command is split shell-word style on quotes and backslashes. Unquoted shell syntax is refused with a
  message, and so is `$` or a backtick inside double quotes, a leading `~` or `#`, and newlines. libghostty runs the
  command through `/bin/sh -c`, so every word is single-quoted. The shell never interprets the user's text.
- Program mode keeps `TERM=xterm-ghostty`, except when the executable's basename is exactly `ssh`.
- New tabs open after the selected tab, in its last directory. The keys are Cmd-T, Cmd-Shift-] and Cmd-Shift-[ with
  wrap, and Cmd-1 to Cmd-9, where Cmd-9 selects the last tab. The Cmd-W item reads "Close Tab" while a pane has more
  than one tab.
- A `TabbedApplet` protocol lets the window route tab keys. `Applet.apply(palette)` has a default no-op. AppletKit now
  depends on Theme.
- Program-mode restore is still refused. M7 builds the Run action.
- The tab-close dialog names a program-mode tab by its command, capped at 80 characters.

Deviations: M5's last-tab check said "a dialog when it would close the window". That dialog belongs to M7's window-close
guard, so the check was amended in place.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | The Decision Log said M8 owns the Run action | Fixed to M7 |
| 2 | As built said a background tab's events never reach the host | Wording narrowed. Notifications and clipboard reads still post, as intended |
| 3 | "Without a shell" was inaccurate | Reworded everywhere |
| 4 | Two fixed 300 ms negative waits | One replaced with a deterministic signal. One kept, with the reason in a comment |
| 5 | Test comment scope and a comment wrap | Fixed |

The reviewer found no injection in program-mode quoting. `it's;*` and `$HOME` reach the program verbatim through real
libghostty.

adr-impact: no conflicts. Both of the implementer's candidates fail the ADR bar. The tab-wide running-state rule was
folded into the existing applet-contract candidate.

Checks left to the user: the tab bar's look, and one real program-mode ssh session to a host without the
`xterm-ghostty` terminfo entry.

Test cost: `swift test` takes 10.8 s of test time for 220 tests. The UI suite takes 231 s for 31 tests.

### M6: Multiple windows

Commit: "Add multiple windows with per-window panes and status".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, `make test-package`, and a build of
  the UI test target, and all passed.
- The coordinator reran `make test-package` independently before the review fixes: 232 tests, 0 failures, and the same
  4 US-layout skips.
- The coordinator ran the UI suite before the review fixes: 37 tests, 0 failures, 279 s.
- After the review fixes, the coordinator reran both suites. `make test-package` ran 236 tests with 0 failures and 4
  skips. The UI suite ran 37 tests with 0 failures in 279 s.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- The implementer mutation-checked 7 behaviors: a shared status center, a shared pane tree, the dock change reaching one
  window only, the appearance change reaching one window only, a close that skips applets, a closed controller kept
  alive, and a set that cannot open again once empty. Each mutation failed a named test.

Restart: the first implementer sat 23 minutes on a cg prompt for `pgrep`. The coordinator had listed `pgrep` as allowed
in its brief, but `pgrep` was added to `.cg.yaml` after the last cg reload. That error was the coordinator's. Every local
check had already passed. The second implementer finished from the tree, using `ps` only.

Best guesses from the implementers:
- File > New Window is Cmd-N. It targets the app delegate, so it works with no window open.
- New windows cascade 28 points from the active window, and wrap to the top left at a screen edge.
- Window identifiers are `main-window`, then `main-window-N`. N counts successful opens and is never reused.
- Closing the last window keeps the app running. Cmd-N or a Dock click opens a window again, and the Settings window
  does not count as a main window.
- A closed controller is kept for one main-actor turn, since AppKit still messages it after `willClose`.
- A message posted with no window open, such as a palette failure, waits for the next window, instead of an alert.
- Two checks were added to M6, by amendment: appearance reaches every window, and closing the last window leaves the
  app running. Both follow from the plan and from "Where settings live".

Review findings, none blocking:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | A comment line over width | Fixed |
| 2 | The Dock-click reopen rule was untested | Moved into a testable rule. The real Dock click is left to the user |
| 3 | A palette failure with no window was only logged | It now waits for the next window, and a test failed first |
| 4 | A failed open burned a window number | Fixed. A test failed on the old code first |

adr-impact: no conflicts. The candidate "the last window closing keeps the app running" fails the ADR bar.

Unowned: about 49 leaked `/bin/sh -c "trap '' TERM; ..."` processes run on the machine, each spawning `sleep 1` children.
They started on 2026-10-24, before this project existed, and use Rust `tempfile` paths. They come from another project's
test. They were reported to the user, and were not touched.

Checks left to the user: the look of cascaded windows, and a real Dock click reopening a window.

### M7: Undo close pane

Commit: "Add undo close pane with grace and description tiers and close guards".

Interruption: the coordinator session was interrupted during M7. The first implementer had written most of the code and
tests but never reported. A new coordinator session resumed the run from the session report, the state file, and git.
It confirmed that the run base was still an ancestor of `HEAD`, that M1 to M6 were committed, and that the uncommitted
tree was M7's alone. A fresh implementer continued from that tree.
- `pgrep` found no orphaned build or test processes.
- `make build` passed on the tree as left. `make test-package` did not compile: a test wrote to a get-only property,
  and two lint errors remained.
- A scan of the diff found no leftover mutation-check edit.
- An inventory against M7's checks found the code behind every check. What was missing was a UI test, the compile and
  lint fixes, and the As built block.

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, `make test-package`, and a build of
  the UI test target, and all passed.
- The coordinator's first UI run, before the review fixes, had 38 tests and 3 failures. Two were M7 regressions: Cmd-Z
  with nothing to undo had gone silent. The third, the Settings appearance test, did not reproduce in 4 isolated runs.
  It overlapped with the implementer's builds in the same DerivedData folder. Its cause is unresolved.
- After the fixes, the coordinator reran both suites on a quiet tree. `make test-package` ran 299 tests with 0 failures
  and the same 4 US-layout skips. `make test-app` ran 39 tests with 0 failures in 301 s. The appearance test passed.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- A mutation of the grace slot bound failed the slot and idle-eviction tests.

Best guesses from the implementers:
- The bounds are a 10 s grace, 3 slots, and an undo depth of 20. They are a policy value with no setting.
- Cmd-Z takes the newest close across both tiers. An undo that does not fit the window is refused with a message, and
  the entry stays.
- When the recorded neighbor is gone, the pane goes on the recorded side of the root along the recorded axis.
- With no grace slot free, an idle hidden pane drops to its description first. When every hidden pane is running, a
  closing idle pane keeps only its description. Declining the full-slot dialog keeps the pane open.
- The quit and window dialogs list up to 8 running tabs plus a count, with Cancel as the default.
- `MainWindow` answers the standard `undo:` selector. Undo stays enabled with nothing to undo, and says so.
- The surface does not expose the OSC 7 host. "Local" means an absolute path that exists here, and the check was
  amended to say so. A remote cwd that also exists locally is accepted, and the shell starts in a wrong but harmless
  directory.
- ADR-02 says a removed node's ID is never reused, but a reattached pane keeps its ID. The run took the narrowest
  reading: a hidden pane still exists, and its ID retires when the pane is discarded. "Pane tree shape" was amended,
  and the pane tree now enforces it. Only a parked ID can be inserted again, and a retired ID is refused. ADR-02's text
  was not edited. If the user reads ADR-02 literally, reattach must mint a new ID, and one M7 check changes.
- A dead last pane stays after a cancelled close when no hidden pane fits, so the window is not empty. It leaves when a
  hidden pane returns.
- The description gained a per-tab starting directory. Older descriptions still read.
- M7 supersedes M5's note that program-mode restore is refused. M5's As built text was left as a dated record.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | The OSC 7 check was looser in code than in text, and was not amended in place | Fixed by amendment |
| 2 | M5's As built said program-mode restore is refused | Dismissed. As built is a dated record, and the Decision Log records the supersession |
| 3 | A dead last pane could stay after a cancelled close | Confirmed by a failing test, fixed |
| 4 | The Cmd-Q delegate wiring had no automated test | UI test added for Cmd-Q with a program running |
| 5 | adr-impact, PLAUSIBLE: reattach reuses a removed ID against ADR-02 | Proposal amended, and the rule enforced in the pane tree with tests |
| 6 | UI: Cmd-Z with nothing to undo posted nothing | Confirmed, fixed. A unit test asserts the message |
| 7 | UI: Settings appearance test failed once | Not reproduced. Diagnosis unresolved |

The retired-ID tree tests use the new `retire` API, so they could not run against the unfixed code. They pin the fix,
not the bug.

adr-impact: ADR-01, ADR-03, and ADR-04 are consistent. Two ADR candidates pass the bar and were recorded as Undecided:
the two-tier undo model, and the window's `undo:` routing. The close-guard running-state rule folds into the existing
applet-contract candidate. For the user: ADR-02's "never reused" wording is older than the amendment that reads it
narrowly.

Checks left to the user: how the grace segment and the Run prompt look, and a real vim buffer surviving an undo.

Test cost: `swift test` takes 12.0 s of test time for 299 tests. The UI suite takes 301 s for 39 tests.

### M8: Layout persistence

Commit: "Save and restore every window's layout across launches".

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, `make test-package`, and a build of
  the UI test target, and all passed.
- Before the review fixes, the coordinator reran `make test-package`: 364 tests, 0 failures, and the same 4 US-layout
  skips. It also ran `make test-app`: 46 tests, 0 failures, 357 s.
- After the review fixes, the coordinator reran both suites. `make test-package` ran 372 tests with 0 failures and 4
  skips. `make test-app` ran 46 tests with 0 failures in 353 s.
- `proposals.py check` and `proposals.py freeze` both print `[]`.
- The implementer mutation-checked 22 rules across two rounds. Each mutation failed a named test, except one. Loosening
  the mode in `open` survives, because `fchmod` sets 0600 before any data is written.
- A mutation showed that the old UI tests passed with the quit save removed, since a debounced save had already written
  the file. A DEBUG-only `UNITERM_LAYOUT_DEBOUNCE` now lets two UI tests depend on the quit save alone.

Best guesses from the implementer:
- The bounds are 3 unfinished launches, a 1 s debounce with a 10 s maximum wait, and 5 keep-asides.
- The ID high-water mark is per window, since each window's tree has its own allocator. A future cross-window address,
  for scripting or trust, would need a window and node pair.
- A second instance opens one default window, restores nothing, and saves nothing. A status message says so.
- A tree larger than the screen caps the window's minimum size to the visible area. Panes overflow at their minimum,
  and the focus keys still reach them.
- The launch marker clears one main-loop turn after the windows show.
- A saved window that fails to open does not stop the others. The file is copied aside before any save replaces it.
- Descriptions are kept as exact file bytes by a small hand-written scanner, since a parsed value would round large
  numbers. A readable description that its applet refuses also becomes a placeholder.
- A frame already inside a screen stays. Otherwise it goes to the saved screen, then the one with the most overlap, then
  the main screen.
- The DEBUG-only UI hooks are `UNITERM_LAYOUT_DIR` and `UNITERM_LAYOUT_DEBOUNCE`.
- A non-finite or non-positive weight is written as an equal share. A stored ID mark above 2^48 is lowered to it, and
  the allocator lowers any mark above 2^62.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | A doc comment bound to the wrong function | Fixed |
| 2 | A title that changes faster than 1 s starved every save until quit | Confirmed by a failing test. Fixed with a 10 s maximum wait, and title-only changes no longer count |
| 3 | A byte-for-byte test skipped instead of failing | Fixed with `XCTUnwrap` |
| 4 | Production traps on the save path | Replaced by a thrown error that reaches the failure route. A pane with no applet is left out instead |
| 5 | Fixed 2 s sleeps in the layout UI tests | One replaced by a poll. One kept as a 1 s negative wait, with the reason in a comment |
| 6 | A dense doc block | Fixed |
| 7 | A quadratic scan on large or deep files | Confirmed by measurement. A single pass per object cut debug decode from 103 ms to 55 ms at 1,000 panes, and from 428 ms to 185 ms at 150 levels. Release takes 14 ms and 9 ms |
| 8 | No drive flush and no directory sync after the rename | Fixed with `F_FULLFSYNC`, falling back to `fsync`, plus a directory sync. A crash cannot be simulated, so this has no test |
| 9 | A non-finite weight written as 0 sent the whole file aside | Confirmed by a failing test, fixed |
| 10 | adr-impact: a hand-edited ID mark could overflow the allocator | Fixed. The allocator test cannot fail first, since the unfixed code traps the test run. The codec side was mutation-checked |

The 185 ms debug decode for a 150-level file is over the coordinator's 100 ms line. It was accepted, since release
takes 9 ms and no real layout nests that deep.

adr-impact: ADR-02, ADR-03, and ADR-04 are consistent, and ADR-01 is untouched. Two ADR candidates were recorded as
Undecided: per-window node ID scope, and the exact-byte description round trip. The second also extends the
applet-contract candidate.

Checks left to the user: a real crash loop, a second real instance, a real unplugged display, how the placeholder pane
looks, and the real "Close windows when quitting" toggle. The UI test sets `-NSQuitAlwaysKeepsWindows NO` instead.

Test cost: `swift test` takes 14.5 s of test time for 372 tests. The 7 layout UI tests take 49 s.

### Row review: M1 to M8

Commit: "Fix undo order, placeholder undo, and background-tab saves found in review".

This run has one row, so the reviewer was also asked for the run's ADR review. The range adds or edits no ADR, and the
reviewer found no ADR finding. The `proposals.py freeze` check with all 8 row commits printed `[]`.

Checks:
- The implementer ran `make fmt-check`, `make lint`, `make check`, `make build`, `make test-package`, a UI test
  target build, and `proposals.py check`, and all passed.
- The coordinator reran both suites. `make test-package` ran 378 tests with 0 failures and 4 skips. `make test-app`
  ran 46 tests with 0 failures in 351 s.

Review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | Undo reopened an older close first when panes dropped to descriptions out of close order | Confirmed by two failing tests. The stack is now ordered by close serial |
| 2 | Undoing a placeholder pane past its grace period lost its saved bytes | Confirmed by a failing test. Undo now reopens a placeholder, as launch restore does, and keeps the entry on failure |
| 3 | A background tab's `cd` never scheduled a save | Confirmed by a failing test. Any tab's description change now tells the host. Segments still follow the selected tab |
| 4 | A launch persistence failure quit silently | Fixed with a critical alert, then quit. An unavailable layout folder instead opens one window that saves nothing, with an error on its bar. No automated test |
| 5 | A launch that failed without crashing still counted toward the crash-loop bound | Confirmed by two failing tests, fixed |
| 6 | A pane that exited while a close question was open was dropped, and left a zombie on Cancel | Confirmed by a failing test, fixed. The comments that claimed a wait were corrected |
| 7 | Dead code and test-only exports | `AppletChoiceError`, `withVerbatim`, and `isHistoryVisible` removed. `keptAsideFiles` made internal. `PaneTree.isRetired` kept, since no public call proves a split ID or a live ID retired |
| 8 | The README status was stale | Updated |
| 9 | `UNITERM_DEFAULTS_PATH` worked in release builds | Now DEBUG-only, like the other hooks |
| 10 | Comment wraps and a dense doc block | Fixed |
| 11 | adr-impact: OSC 52 writes never ask, so the write dialog was unreachable | The unreachable path was removed. Writes stay allowed without asking, as the proposal requires confirmation only for reads. Recorded in the Decision Log and the clipboard ADR candidate |

Best guesses from the implementer:
- An unavailable layout folder continues with one window that saves nothing, following the second-instance precedent.
  If the user prefers, a small change in the app delegate turns it into alert and quit.
- A launch that opens no window clears the unfinished-launch count. That also resets any earlier count. A
  deterministic non-crash failure should not move a good layout aside.

adr-impact, over the whole range: ADR-01, ADR-03, and ADR-04 are consistent. ADR-02's wording still says a removed
node's ID is never reused, while the code and the amended proposal retire it only on discard. That is for the user.

### Final review

Commit: "Ask once and settle pane exits during close questions".

The final review covered the run's whole range, focused on the row-review fix commit. It doubled as the run's ADR
review. The range adds or edits no ADR, and `proposals.py freeze` with all 9 commits printed `[]`. adr-impact on the
fix commit found no conflict. It named two uncovered decisions. The silent OSC 52 write is already part of the
clipboard candidate. The no-save window for an unavailable layout folder fails the ADR bar, since it is one
component's failure policy.

Checks: the implementer ran every local check, and all passed. The coordinator reran `make test-package` with 380
tests, 0 failures, and 4 skips. It also ran `make test-app` with 46 tests, 0 failures, in 349 s.

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | A Cancel with no room to reattach asked the window-close question twice | Confirmed by a failing test. One Cancel now keeps the dead pane and asks nothing more |
| 2 | An exit recorded during a pane-close question was dropped on Confirm | Confirmed reachable by a failing test. Confirm now closes it as an exit |
| 3 | Five in-place proposal edits lacked Amended markers | Fixed. The Decision Log entry now states the current exit behavior |
| 4 | Two long proposal lines | Rewrapped |
| 5 | A doc comment with a lone last word | Rewrapped |
| 6 | OSC 52 writes go through without asking | Left for the user. It matches the proposal, which asks only for reads |

## ADR candidates

These are the candidates as they stood after the follow-up:
- Undo close and the applet lifecycle: written as ADR-05. The user reframed it as a lifecycle rule. uniterm sends the
  events, and each applet owns its response.
- Description versioning: written as ADR-06. The user reframed it as two-layer versioning. uniterm owns the envelope,
  and each applet owns its payload and its version.
- The rest of the applet contract: waits on the applet drafts, UTERM-005 to UTERM-010.
- Clipboard trust: still Undecided. It may wait on UTERM-004.
- Per-window node ID scope: still Undecided. It may wait on UTERM-003 and UTERM-004.
- Cmd-Z routing: still Undecided. The coordinator recommends no ADR, since only the window's key handling depends on it.

## Follow-up after the run

After the run, the user reviewed the open items in the same session.

- ADR-02 first gained a sentence saying a pane kept for undo keeps its ID. That sentence was removed later the same
  day, when keep-alive was removed.
- ADR-05 and ADR-06 were written. ADR-05 was first written as "detached applets go quiet, and the host bounds their
  background life". The user then ruled that uniterm only sends lifecycle events, and each applet owns its response.
  ADR-05 was rewritten in place to say so, at the user's direction.
- The drafts UTERM-003 to UTERM-010 gained context notes on the applet contract, pane ID scope, and clipboard rules.
- A design for pausing a hidden terminal with SIGSTOP was reviewed against macOS and Linux signal semantics. The review
  found that `login(1)` is the session leader and that a default-action SIGHUP kills a stopped process at once on XNU.
  It also found that other threads run before a pending SIGHUP handler. A pty spike in bash 3.2, bash 5.2, and zsh 5.9
  confirmed that stopping the shell first and resuming it last hides the stop from job control. The design was dropped
  when the user ruled that undo is not a process snapshot.
- M10, "Undo reopens from the description", was added by amendment and built. It removed the grace slots, the grace
  segment, reattach, parked IDs, and the hidden-pane guards. Closing a pane that is running something now asks first.
  A detached terminal holds back notifications until reattach.

M10 checks:
- The implementer ran every local check, and all passed. `make test-package` ran 364 tests.
- The coordinator's first UI run had 46 tests and 1 failure, `testClosingAPaneGivesItsSpaceToTheNeighbor`. It failed
  while dismissing the new-pane picker, before any close. It did not reproduce in 4 later runs. The implementer's
  package checks overlapped that run, so load is the likely cause. That diagnosis is unresolved. The test now waits
  for the shell's prompt before it closes the pane, which removes a separate race.
- After the review fixes, the coordinator reran both suites. `make test-package` ran 364 tests with 0 failures and 4
  skips. `make test-app` ran 46 tests with 0 failures in 347 s.

M10 review findings:

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | The terminal's detach did not hold back its notifications, against ADR-05 | Fixed. It keeps the newest notification and posts it on reattach. A test failed first |
| 2 | A stale doc on `setVisible` | Fixed |
| 3 | A late message from a closed applet posts with pane ID 0 | Kept, with a comment and a test that pins it |
| 4 | A dead pane closed later could add an undo entry | Confirmed by a failing test, fixed |
| 5 | A Decision Log entry named the wrong section | Reworded |

The `.cg.yaml` allowlist was committed at the user's direction.

## M9: User visual check

A second `/work-queue` run took the row on 2026-11-01. Its base commit was "Merge pull request #5 from
space-armada/agent/petunia/uterm-001". M9 had no code to build, so no implementer ran for it. The coordinator built and
launched the app with `make run`, outside the sandbox, and the user reviewed it.

The user's verdict:
- The font, the font size, and the Latte and Mocha colors look good.
- The window chrome looks good.
- Nested panes look good, and so does the warning when a split runs out of room.
- The status bar looks good at the top and the bottom, with one bug. After the theme is switched to Dark, the directory
  segment moves from the trailing edge to the leading edge. Light, System, commands, docking, and resizing do not
  restore it. Opening a new pane does, and it stays fixed after that pane closes.

Checks:
- The app built and launched. It exited with status 0 when the user quit it. No new uniterm crash report appeared.
- `proposals.py check` and `proposals.py freeze` both print `[]`.

Best guesses:
- The status bar bug does not block M9. The project's "UI Feedback" rule ships review tweaks as ordinary UI changes.
  The user's standing rule is to fix a reported bug, so an implementer took it on. If the bug should block M9 instead,
  M9 goes back to `IN PROGRESS` and UTERM-001 back to `accepted`.
- The implementer could not reproduce the bug in a package test, a scratch view test, or a UI test. Then the user could
  not reproduce it on a fresh build. At the user's direction, no fix was made. The bug is filed at
  `spec/bugs/20261101-status-bar-segment-leading-after-dark.md`, and M9's As built was corrected with a Decision Log
  entry. The implementer's two non-reproducing tests are in a local git stash named "status bar bug: tests that do not
  reproduce it".
- This report is amended in place rather than a new one started, since it is the row's report.

## Status

Finished. UTERM-001 is `implemented`, and its row is in `history.md`.
