# UTERM-002 M1-M3: Command palette work-queue run

Started 2026-11-01. This report covers a `/work-queue next 2` run. Its first row is `UTERM-002 M1-M3`, the command
palette, at `spec/proposals/UTERM-002-command-palette.md`. Its second row is `UTERM-013 M1-M2`, shortcut ownership and
reopening closed tabs, reported in [20261101-uterm-013-m1-m2-shortcut-ownership-and-reopen.md](
20261101-uterm-013-m1-m2-shortcut-ownership-and-reopen.md). The specs live in the code repo, so every commit below is
in this repo, on `main`. Nothing is pushed.

## TL;DR

The run finished on 2026-11-02. Both rows are done, and UTERM-002 and UTERM-013 are `implemented`. The five milestones
each landed in their own commit, followed by a review-fix commit and a finishing commit per row, and a final-review
commit. The last checks were `make test-package` on the final commit with 540 tests, 4 skipped, and 0 failures, and two full `make test-app`
runs with 77 of 77 UI tests passing. `make ghostty-offline-check` passed.

For the user:

- One full UI run during UTERM-013 M2 failed 5 tests that passed in two later full runs. The cause is unresolved. See
  the UTERM-013 report.
- ADR-03, ADR-04, and ADR-05 still say Cmd-Z or "undo" brings back a closed pane. Their decisions still hold. A minor
  wording edit would match Cmd-Shift-T. The run left the ADRs alone.
- No new ADR candidate passed the bar. The candidates raised were already declined or deferred in the Decision Logs.

## Run state

- Base commit for the run and for the first row: "Merge pull request #6 from
  space-armada/agent/petunia/finish-foundation-schedule-palette"
- Specs commits: the specs live in the code repo, so the milestone commits are the specs commits

| Milestone | Run status | Commit |
|-----------|------------|--------|
| UTERM-002 M1 Floating palette with commands | DONE | "Add a command registry and a floating command palette" |
| UTERM-002 M2 Tab search | DONE | "Let the command palette find every tab in the window" |
| UTERM-002 M3 Docked mode | DONE | "Let the command palette dock at the top or bottom of the window" |
| UTERM-002 row review | DONE | "Ask the applet before hiding the palette, and tidy the row" |
| UTERM-013 M1 Applet-declared shortcuts | DONE | "Let applets declare their own shortcuts and reserve uniterm's window keys" |
| UTERM-013 M2 Reopen with Cmd-Shift-T | DONE | "Reopen the newest closed tab or pane with Cmd-Shift-T" |
| UTERM-013 row review | DONE | "Tidy shortcut ownership after review" |
| Final review | DONE | "Mark the palette's first milestone as superseded in part" |

Held or blocked rows: none. UTERM-013's row depends on UTERM-002 M1, which this run builds first.

## Local checks

Every milestone runs `make fmt-check`, `make lint`, `make check`, `make test-package`, and `make test-app`. The UI
tests run outside the sandbox, since they drive the app through Launch Services and Accessibility. `make
ghostty-offline-check` runs once, at the final review, since no milestone touches `ghostty.pin`.

## Run-level best guesses

These come from the approved plan at `~/.claude/plans/spicy-weaving-fern.md`.

- UTERM-002's grace-tier lines are stale, since UTERM-001 M10 removed grace-tier panes. M2 amends them as a correction
  of fact.
- An unavailable command is shown disabled, not hidden. If wrong, the palette filters them out instead.
- The floating palette is an overlay view inside the window, not an `NSPanel`.
- The click that dismisses a palette is delivered normally to what it hits.
- When the palette and the status bar dock at the same edge, the status bar is outermost.
- The closed-tab list depth is 20, matching the pane undo depth.
- Ranking constants, debounce intervals, and overlay sizes are the implementer's, recorded in As built.
- UTERM-002 M1 leaves the Close Pane / Close Tab title switch alone. UTERM-013 M1 renames it to "Close".

## Milestones

### UTERM-002 M1: Floating palette with commands

Commit: "Add a command registry and a floating command palette". It also carries the `.cg.yaml` fix that points the
`proposals.py` allow rule at the current plugin version.

Checks, final round: `make fmt-check`, `make lint`, and `make check` pass. `make test-package` ran 437 tests, with 4
skipped and 0 failures. `make test-app` ran 59 UI tests, with 0 failures, in 437 seconds. `proposals.py check` and
`proposals.py freeze` report nothing.

Test cost: the new unit test files take about 0.9 seconds together. The 8 new UI tests in `CommandPaletteUITests` take
54 seconds.

Best guesses by the implementer:

- The registry lives in a `Commands` folder of WindowKit, not a new module.
- The palette-focused dispatch rules live in one dispatch point on the window controller, not in the key route. A
  menu item chosen with the mouse then gets the same rules, which an M1 check requires. "Command source" was amended
  for it, with a Decision Log entry. If wrong, the rules move into the key route, and mouse-chosen items lose them.
- Terminal text actions, such as text size and clear, reach the terminal through a new applet-contract protocol for
  text actions. WindowKit cannot import the terminal module.
- Palette sizes, match scoring, and the recency boost are recorded in the M1 As built block.
- Close is titled "Close Tab or Pane" in the palette. Select-tab-by-number and the palette toggle are not listed.
- Unavailable commands show disabled, and the arrow keys and Enter skip them. A pane-scoped command whose pane is gone
  counts as available, so choosing it posts a status message.
- A click outside the floating palette on something that takes no keyboard returns focus to the prior pane. M3
  states this for the docked palette. M1 applies it to floating too.
- The UI tests apply App Shortcuts remaps with the `-NSUserKeyEquivalents` launch argument.

Deviations and defects found along the way:

- Cmd-Z in the palette's field did nothing until the window routed undo through the field editor's undo manager.
- A second Cmd-Q cancelled the open quit question. Quit is now the app delegate's own item, disabled while the
  question is open.
- No UI test drives a sheet over a showing palette. A unit test covers the rule that hiding never takes focus back.

Review findings:

- Decision Log entry out of date order: fixed.
- Two comment-craft nits: fixed.
- The "Command source" marker date replaced the earlier one: dismissed, since `proposals.md` says a later revision
  replaces the marker.
- Unlisted commands, such as Cmd-1 to Cmd-9, filled the 8-deep recency list: traced and confirmed, then fixed with a
  test. Only commands listed in the palette count toward recency now.
- The key route missed menu items whose key differs from the typed character, such as Bigger Text on Cmd-+ and
  Dismiss Message on Delete: traced and confirmed, then fixed with tests. Cmd-} and Cmd-Shift-] are still not unified.
  UTERM-013 M1 owns that canonical form.

ADR review: no conflicts. Two uncovered decisions were raised, and neither is recorded as a candidate. The window key
route is mechanism that UTERM-013 keeps out of ADR-04 on purpose. A registry ADR was already declined on 2026-11-01.

### UTERM-002 M2: Tab search

Commit: "Let the command palette find every tab in the window".

Checks, final round: `make fmt-check`, `make lint`, and `make check` pass. `make test-package` ran 467 tests, with 4
skipped and 0 failures. `make test-app` ran 62 UI tests, with 0 failures, in 472 seconds. `proposals.py check` and
`proposals.py freeze` report nothing.

Test cost: `TabSearchTests` runs 18 tests in about 0.4 seconds. `AppletTabTests` takes about 0.001 seconds. The three new
UI tests take 8 to 14 seconds each.

Best guesses by the implementer:

- The applet contract publishes a tab list built as a first tab plus the rest, so an empty list cannot be built. A new
  host signal reports any tab change, background tabs included. The old change signal is kept for titles and segments.
- Launcher and placeholder panes publish one tab, titled by the applet's title.
- The palette re-lists at once on typing and on tree-shape change. Tab and layout changes are held for 100 ms, so a
  burst becomes one pass. The interval is unmeasured.
- Tab recency uses the same bounded boost as commands, and keeps the 64 most recent tabs.
- The current tab is listed and marked. On an empty or blank query, the first choice is the most recent other tab.
- Titles and details are neutralized:
  - Control characters, line breaks, and wide spaces become one space.
  - Bidi and format controls are dropped, except a ZWJ inside an emoji sequence.
  - The text is capped at 120 Unicode scalars.
  - Text with nothing left reads as "Untitled".
- Typing re-highlights the top result on each keystroke, even after an arrow key. A re-sort from a tab or layout change
  keeps the highlight by ID.
- The stale grace-tier lines in "How applets publish tabs" and in the M2 checks were amended as a correction of fact.
  UTERM-001 M10 removed hidden panes. The check now says a closed pane's tabs do not appear.

Residuals: a real split or undo while the palette shows is covered by unit tests only. The terminal's own 80-character
title cap counts grapheme clusters, so it does not bound combining marks. The palette's own cap does. A program-mode
tab waiting to run is listed by its program name.

Review findings:

- The neutralizer's cap counted grapheme clusters, and invisible-only titles showed blank rows: traced, confirmed by
  tests that failed on the unfixed code, and fixed.
- A blank query highlighted the current tab, and clearing the query kept a stale highlight: traced, confirmed by a
  test that failed on the unfixed code, and fixed.
- A test that proved only the fake applet's behavior: retired. A terminal restore test already covers the contract.
- An overlong proposal line and a stale `**Updated:**` date: fixed.

ADR review: no conflicts. The two uncovered decisions it raised are one tab per applet and never-reused tab IDs. That
candidate was declined on 2026-11-01, so it is not recorded again.

### UTERM-002 M3: Docked mode

Commit: "Let the command palette dock at the top or bottom of the window".

Checks: `make fmt-check`, `make lint`, and `make check` pass. `make test-app` ran 69 UI tests, with 0 failures, in 526
seconds. The review fix round changed only key-name text, so it re-ran `make test-package` but not the UI tests.
`make test-package` ran 496 tests, with 4 skipped and 0 failures. `proposals.py freeze` reports nothing. `proposals.py
check` reports only the row-finishing steps that follow the row review.

Test cost: the 7 new UI tests in `DockedPaletteUITests` take 4.5 to 8.6 seconds each. The new unit test files are
negligible.

Best guesses by the implementer:

- When the palette and the status bar dock at the same edge, the status bar is outermost and the palette sits inward.
  The order is fixed by role, whatever the install order.
- The deactivating click goes to the view under it, including a mouse-reporting terminal. A UI test turns on mouse
  reporting in a shell and sees the press arrive.
- A mode or edge change while the palette is active deactivates it and returns focus to the prior pane.
- The floating palette's results are now a separate card 4 points below the field, so both modes share one results
  view. M1 drew one card with a divider.
- Clicking the inactive strip outside its field does nothing, so the press that deactivates the palette cannot
  reactivate it.
- The message history panel now starts at the pane area's edge, not at the status bar. A palette on the bar's edge is
  then not covered by it.
- UI tests set the palette settings through a `settings:` launch helper that writes the isolated defaults before
  launch.
- "Default mode and dock edge" and "What an inactive docked palette shows" were amended, with a Decision Log entry.

Residuals: the placeholder does not refresh for a remap made while the window is already key, until the next
activation or key event. The history panel beside a palette on the bar's edge is untested for overlap. A split pane
under the overlay is not covered.

Review findings:

- The placeholder showed a private-use glyph for F-keys, Home, End, and similar keys: traced, confirmed by tests that
  failed on the unfixed code, and fixed. An unknown private-use key now leaves the hint out.
- Constants listed in the As built block: dismissed, since the plan asked for chosen constants to be recorded.

ADR review: no conflicts. The region order and the click delivery are mechanism inside one component and easy to
reverse, so neither passes the ADR bar.

### UTERM-002 row review

The review covered the three milestone commits together.

Findings and dispositions:

- M3's As built repeated M1's constants, against M1's claim that they live only there: fixed. M3 now records only
  the values it added.
- The floating palette and an active docked palette still read "Search commands", stale since M2 added tabs: fixed.
- Two split helpers had no production callers after M1 moved splits onto the registry: fixed. They moved into a
  test-only extension, since about 100 test call sites use them.
- An empty `if` branch held only a comment: fixed.
- Choosing a tab hid the palette before asking the applet to select it, so a refused selection would leave the
  keyboard nowhere with no message: traced and confirmed. The palette now asks the applet first, and a refusal
  takes the gone-tab path. A new test covers it. It was not run against the unfixed code.

Shape notes for UTERM-013 M1, passed to its implementer:

- The registry types are internal to WindowKit, while the menu is built in the App target. Menu generation must widen
  the types or move menu building into WindowKit.
- Each command is described in four places: its ID, its registry entry, a selector-to-ID switch with an adapter, and
  its menu item. Carrying the command ID on the menu item removes the last two.
- The registry has no registration API, so applet-owned commands need one.
- The menu key match prefers a remapped item even when it is disabled. The reserved set should decide that case
  explicitly.

Fix commit: "Ask the applet before hiding the palette, and tidy the row". Checks: `make lint`, which includes
`fmt-check`, and `make check` pass. `make test-package` ran 497 tests, with 4 skipped and 0 failures. `make test-app`
ran 69 UI tests, with 0 failures.

Row finish commit: "Finish the command palette". UTERM-002 is `implemented`, the index says so, and its row
moved to `history.md`. `proposals.py check` reports nothing.

ADR review over the row: no conflicts. Its three candidates were already settled. The registry and the one-tab rule
were declined on 2026-11-01. The key route is mechanism that UTERM-013 keeps out of ADR-04.

## Final review

The review covered the whole run. It found no correctness or security defect, and confirmed that the run edits no
ADR. `proposals.py freeze` over all the run's commits reports nothing.

Findings and dispositions:

- UTERM-002 M1's As built describes shapes that UTERM-013 M1 later replaced: fixed. M1 now carries "Superseded in part
  by UTERM-013", with a Decision Log entry. The As built text stays as written, since it was true when it shipped.
- Two UTERM-013 markers read "2026-11-01 and 2026-11-02", and some lines wrap ragged: dismissed. UTERM-013 is
  implemented, and the freeze allows only corrections of fact.
- ADR-03's rationale and ADR-04's context still say Cmd-Z gets a closed pane back, and ADR-05 calls reopen "undo":
  left for the user. No decision changed, so a minor wording edit would do. No superseding ADR is needed.

Fix commit: "Mark the palette's first milestone as superseded in part". `make ghostty-offline-check` passed in 80
seconds.

The ADR review over the run found no conflicts. Its candidates match the Decision Logs: the registry and the one-tab
rule were declined on 2026-11-01, and the command ID namespace and the host-stamped closes are deferred to UTERM-003 and
to UTERM-005 through UTERM-010.

## Status

Done. Every change in this run is committed on `main`. Nothing was pushed. The working tree holds only the
user's `.cg.yaml` allowlist edits, which get their own commit.
