# UTERM-005 M8: browser remote control work-queue run

Started 2026-11-20. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-005 M8`, from `spec/proposals/UTERM-005-browser-applet.md`. M8 lets a controller drive the browser through
UTERM-004's control framework, under two new typed permissions, browser navigation and browser read. The specs live in
the code repo, so every commit below is in this repo, on the `agent/petunia` branch.

## Run state

The run's base and the row's base are both the commit "8< --- snip ---" that follows "Record reruns of the three UI
tests that failed once in the UTERM-008 M3 run". Step 0 fetched `upstream/main`. The branch already sat on it, so no
rebase ran, and `snips.py list` found no redundant snips.

The row's one dependency, UTERM-004 M6, is met. M8 carries no `Live after` line. Nothing is held, blocked, or skipped,
and no work is stashed.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-005 M8: Remote control | DONE | See "Commits" under M8 |

The row is finished. UTERM-005 is `implemented`, the index says so, and the row moved from `queue.md` to the end of
`history.md` in "Mark UTERM-005 implemented now that a controller can drive the browser".

The run's commits, in order:

1. "Let a controller drive its own browser tabs"
2. "State the browser's command skew and its contract additions plainly"
3. "Mark UTERM-005 implemented now that a controller can drive the browser", which also carries this report's
   amendments

## Run-level best guesses

These come from the approved plan.

1. Tab ownership keys on an explicit caller token passed through the validated command, not on the pane's control
   generation alone. Rests on CLAUDE.md "Applet Attributes" and ADR-14. If wrong, only the token source changes.
2. Permissions are gated in the dispatcher through a per-command schema field, so UTERM-019's later kinds reuse it.
   Rests on ADR-14 "Authorization is checked at the effect boundary". If wrong, the check moves into the applet.
3. A browser power the run does not hold gets a structured error and never a question. A declared power not yet
   standing follows pane control's existing ask. Rests on M8's check that pane control alone gets a structured error.
4. "Holds key focus" means the pane's view holds the window's first responder, whatever the window's key state. It is
   the more protective reading of ADR-12. The cost: in a window where the browser is the only pane, its selected tab
   cannot be navigated, so a controller works in background tabs.
5. Controller URLs pass the same address policy as typed input, with the controller source. A scheme-less host gets
   HTTPS and loopback gets HTTP. Rests on "Schemes": one rule for typed, restored, and controller input.
6. The first tab of a pane a run's layout created belongs to that run. Rests on ADR-14: the run opened the pane.
7. A download in a controller tab is held for the existing download question, which shows when the tab is selected.
   Rests on "only the selected tab asks".
8. The new error codes ride on existing Janet failure kinds, with no ScriptWire bump. Rests on UTERM-019 "Capability
   names and the unavailable error" and ADR-13.
9. The browser's command schema starts at 1.0, as the image viewer's and the map's did.
10. `read` targets one owned tab. No list command is added, since `open` returns each tab's reference.
11. A script's generic tab open is refused for browser panes, since it carries no URL and `open` covers it under the
    right permission.
12. Exec drivers hold browser powers from their run's grants, as they hold clipboard grants. Rests on ADR-14: every
    control entry point uses the same permission boundaries.
13. UTERM-004 is implemented and frozen. It names the two kinds through a "Superseded in part by UTERM-005" marker and
    its Decision Log entry, the only edit its freeze allows.

## UTERM-005 M8: Remote control

### Commits

All in this repo. "Let a controller drive its own browser tabs" carries the milestone, its review fixes, the proposal
edits, and this report.

### What was built

- Browser navigation and browser read join `controller.json` format 2 at version 1. Format 1 still refuses them. The
  policy file stays at format 1. A pane-control approval stored before them covers neither.
- The review sheet says navigation is network access signed in as the user, and read returns addresses that may carry
  tokens.
- A command in an applet's schema may name the power its caller must hold. The shared dispatcher refuses it before any
  effect, and checks again at delivery. The validated command carries an explicit caller token and its target tab.
- The browser adopts the command hook at schema 1.0: `open`, `navigate`, `reload`, `back`, `forward`, `select`, and
  `read`. It declares remote control and no exec.
- A tab `open` makes, and the first tab of a remote-controlled layout pane, belong to the caller. The map clears on a
  new control generation, at grant end, and on tab close. Page-opened, reopened, and restored tabs never enter it.
- Refusals use four new codes: `permission-missing`, `not-owned`, `key-focused`, and `unsent-input`. Janet sees them as
  refused or busy, with the reason in the message.
- Controller reload, back, and forward set no resend intent. A test measured one POST after a controller reload.
- In a controller tab, every app handoff asks, `mailto:` included, and every download waits for the download question.
- Owned tabs that never loaded load at start and on reattach.
- A layout's browser pane takes a `url` seed, which needs browser navigation and passes the controller address policy.
- A script's generic tab open is refused for a browser and names `open`.
- Exec drivers get browser powers through a question kept for the run, like clipboard grants.
- The tab bar and profile button stay clear of the control badge.
- A grant holds at most 16 live tabs per pane. This was added after review.
- UTERM-004 carries a "Superseded in part by UTERM-005" marker and Decision Log entry naming the two kinds.

### Checks

- `make lint` and `make check`: pass.
- `caffeinate -dimsu make test-package`: 2988 tests, 10 skipped, 0 failures, after the review fixes. The first run
  failed 3 `BuiltInAppletsTests` assertions that pinned the browser as disconnected only with no command hook. M8
  changes that on purpose, so the assertions were updated.
- `make fuzz`: 23 tests, 0 failures.
- `build-for-testing`: succeeded.
- `BrowserRemoteUITests`, filtered run by the coordinator: failed once, then passed after the harness fix below. The
  coordinator read its screenshot. The seeded tab shows its page. The controller's second tab sits unselected beside it,
  since the layout gave the pane focus. The badge stands clear of the profile button.
- `proposals.py check`: only the two row-finish findings the row review handles. `proposals.py freeze`: one UTERM-004
  References hunk, origin `other`. See "Left for the user".

### Test cost

Wall time per new class, run alone with `swift test --filter` on a built package:

| Class | Tests | Wall time |
|---|---|---|
| `BrowserRemoteTests` | 24 | about 2.2 s |
| `BrowserWindowTests` | 9 | 0.86 s |
| `BrowserDriverTests` | 4 | 0.43 s |
| `ControlDispatcherPermissionTests` | 5 | 0.005 s |
| `LayoutSeedParseTests` | 2 | 0.002 s |
| `BrowserRemoteUITests` (UI) | 1 | 20 s |

`BrowserRemoteTests` drives real WebKit against a local server. Only that layer can prove resend, downloads, handoff,
and ownership against a real page.

### Implementer best guesses and deviations

1. ADR-12 was retracted on 2026-11-20, after the plan cited it for the focus guard. M8's own text and the "Control"
   rationale still say commands never take the keyboard. The implementer built to the proposal text, and the As built
   names the mismatch.
2. When the pane does not hold the keyboard, `open` selects its new tab. The plan only covered the key-focused case.
3. Tab commands take an optional `tab` argument holding the text `open` replies with. The exec wire has no tab field,
   so without it a driver could open tabs and never act on them. A target and argument that disagree are refused.
   Recorded in the Decision Log as a work-queue best guess after review.
4. Key focus is checked before unsent input, since typing implies both.
5. A driver's browser power comes from a run-scoped question, since a driver's attachment holds no declared
   permissions. The plan said "derive from the run's grants".
6. `read` answers with the last committed or stored address while a first load is in flight.
7. A seeded layout pane that is disconnected gives no ownership.
8. A seed keeps its scheme's spelling, such as `HTTP://`. Only the policy decision lowercases it.
9. The script window API gained a required power lookup, and `sendCommand` and `requestLayout` gained a `powers:`
   parameter.
10. A grant may hold 16 live tabs per pane, matching the browser's held-download and waiting-dialog limits. Past it,
    `open` fails busy before any tab is built. Tagged in the Decision Log as a work-queue best guess and an addition.
    Its test was written with the cap and was not run against code without it.

### Review findings

Reviewer:

1. A doc block merged onto `insert` from `selectTab(at:)`. Fixed.
2. The `tab` argument was in As built only, not in the Decision Log. Fixed.
3. Nothing bounded the tabs one controller opens (PLAUSIBLE). The trace confirmed that no existing bound applies. Fixed
   with the cap in best guess 10.
4. Comment placement in `BrowserView.swift` and a ragged wrap in `LayoutRequest.swift`. Fixed.

ADR impact: no conflict and no supersession. ADR-14, ADR-03, ADR-06, ADR-11, and ADR-13 are consistent. It named three
uncovered decisions, each weighed below.

Coordinator's UI run: the first run's loopback server saw no requests. The UI test runner is sandboxed with
`network.client` only, so its listener became ready but never accepted the app's connections. The test now runs a perl
server from the unsandboxed shell it already drives. This was a harness bug, not a product bug, and the assertions kept
their strength.

### ADR candidates

Weighed against "What Earns an ADR":

- Per-command powers in the shared command contract. A schema command names the power its caller needs, and dispatch
  refuses it before the applet sees it. It binds every applet and every control entry point. It is costly to reverse
  once UTERM-019 and UTERM-020 add kinds. Nothing in the code shows the rule. It passes, and is recorded as
  `Undecided` in UTERM-005's Decision Log.
- Ownership of sub-pane objects keyed on the grant. Controllers own browser tabs, not just panes, and ownership ends
  with the grant. ADR-14 covers panes and windows only. Other tabbed applets would copy it. It passes, and is recorded
  as `Undecided` too.
- Refusing controller actions on a key-focused or unsent-input target. This is a user question raised by ADR-12's
  retraction, not an ADR candidate. See "Left for the user".

### Bugs found

None in the product. The first UI-test failure was a harness bug, fixed in the test.

### Left for the user

- ADR-12 was retracted the same day the plan cited it. UTERM-036 now says a program's opens and layouts take focus as
  the user's do. M8 still refuses `navigate`, `reload`, `back`, and `forward` on the selected tab of a key-focused pane,
  and `open` there leaves the user's tab selected. UTERM-036 does not list UTERM-005 in its Impacts, so M8's text
  stands. One effect shows in the UI test: a layout focuses its new browser pane, so a controller cannot navigate its
  seeded tab until the user moves focus. The user decides whether M8's focus rules should follow the retraction.
- `proposals.py freeze` reports a UTERM-004 References hunk for ADR-14, origin `other`. Another session committed it
  after UTERM-004's freeze commit. This run left it alone.
- VoiceOver on the new review lines is untested.

## Row review and final review

The row has one milestone, so the row review and the run's final review cover the same range: the run's base to the
commit "Let a controller drive its own browser tabs". One reviewer pass did both, with the ADR review. The range adds
and edits no ADR.

Findings:

1. The built focus rules differ from the retracted ADR-12's replacement principle. Disposition `user`. It is the
   question already under "Left for the user" above.
2. "The applet contract" Rationale still said the browser needed no contract change. Fixed.
3. No skew statement covered the new exec-wire error codes and the `tab` argument (PLAUSIBLE). The trace found only
   shared dispatch and the browser's new commands throw them. An older driver or script never reached a browser
   command, and an older app refuses the browser's commands before any effect. No defect. M8's As built gained the
   skew paragraph.
4. The two ADR candidate entries are not ADR-ready. Dismissed: a logged candidate records the invariant and its
   outcome, and the ADR is written only when the user asks.

The fixes landed in "State the browser's command skew and its contract additions plainly". Its body opens by
describing the earlier rationale, which `commit-style.md` forbids. The reword with `git commit --amend` was denied by
the permission check, so the message stands as written.

The full UI suite ran once, with `caffeinate -dimsu make test-app`, during this review. See "Full UI suite".
