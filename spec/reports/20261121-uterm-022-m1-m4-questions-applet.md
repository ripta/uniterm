# UTERM-022 M1-M4: Questions applet work-queue run

Started 2026-11-21. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-022 M1-M4`, from `spec/proposals/UTERM-022-questions-applet.md`. UTERM-022 lets a bash script or a Janet
program ask the user a form and wait for the answers, in a Questions pane with uniterm-drawn requester chrome. The
specs live in the code repo, so every commit below is in this repo, on the `agent/petunia` branch.

## Run state

The row depends on UTERM-021 M4, which is done. No milestone carries a `Live after` line. Nothing is held, blocked, or
skipped.

Step 0 rebased the branch onto `upstream/main`, twice. The second time picked up "Merge pull request #86 from
ripta/agent/petunia-land/browser-as-user", which landed during the step. The run's base and the row's base are both the
snip commit that sits directly above "Carry UTERM-042's decisions into the proposals that cite them".

Step 0 had an incident. The first snip drop ran while the user was rebasing the same branch by hand. The script aborted
the user's rebase. A follow-up `git stash pop` then applied the user's unrelated stash from 2026-11-01, "status bar
bug: tests that do not reproduce it", to the working tree. The run put that stash back on the stash list unchanged,
restored the two files it touched, and restored `.cg.yaml` from a saved diff. The run then did the user's requested
swap with plumbing, so the snip now sits above the UTERM-042 commit. Every later stash in the run carries a name, and
is checked by name before it is popped.

`.cg.yaml` holds three rules this run did not add. They name absolute scratchpad paths. The run leaves the file
uncommitted.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-022 M1: Form spec and validation | DONE | "Read and check script-asked form specs" |
| UTERM-022 M2: Questions applet UI | DONE | "Show script-asked forms in a Questions pane" |
| UTERM-022 M3: The ask power and the form calls | DONE | "Let scripts ask the user a form and wait for the answer" |
| UTERM-022 M4: `uniterm ask` and Janet helpers | QUEUED | |

## Commands that leave the sandbox

- `git fetch upstream`, for the SSH key.
- `make build` and `make test-helper-sandbox`, in every milestone.
- `make test-app` and the filtered UI runs, which the coordinator runs.

## Local checks

The implementer runs these through `cg_run`: `make fmt-check`, `make lint`, `make check`, `make build`,
`caffeinate -dimsu make test-package`, `make test-helper-sandbox`, `proposals.py check`, and `proposals.py freeze`. It
adds `scripts/swiftpm-offline-check.sh` when `Package.swift` changes, and a scoped `make fuzz` when the spec reader, the
wire, or the declaration reader changes.

The coordinator runs the UI tests through `cg_run` under `caffeinate -dimsu`. It runs a filtered `-only-testing:` run
of the touched classes, after a one-class probe, and one full `make test-app` before the row review. After each UI run
it lists the crash-report folder.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. M1's reader widening is already built, by "Keep a newer policy file that holds a boolean, null, or fraction". M1
   verifies it. If the guess is wrong, M1 would rebuild work that already passes its tests.
2. The spec caps come from the reply encoder: 4096-byte strings, 64 record fields, 32-byte ASCII keys, and the reply
   payload cap. Decoding computes a worst-case result size and refuses a spec over budget, naming the field. This rests
   on M1's "fits one reply" check. If it is wrong, a script could get an answer that the encoder cuts short.
3. JavaScriptCore is linked to the M1 test target only, for the differential test. It is a system framework. If the
   guess is wrong, the app would gain a JavaScriptCore link it does not use.
4. The form UI is AppKit. This rests on CLAUDE.md "Stack Decisions", which keeps SwiftUI to small leaf views. If it is
   wrong, M2's views would move to SwiftUI.
5. M2 is tested in-process, and its UI tests open forms through a debug-only fixture hook, as `AppletFixtures` does. M2
   has no wire calls yet. If the guess is wrong, M2's UI checks would wait for M4's command.
6. The asking-pane badge is a host-drawn marker in the pane frame, beside the control badge. UTERM-041's shared marker
   slot is unbuilt. If the guess is wrong, the badge would move into that slot when UTERM-041 lands.
7. A host-side form-handle table follows the text viewer's handle table: a cap, and eviction of the oldest settled
   entry. This rests on ADR-11 and "Lifecycle and results".
8. The wire adds a question-only begin as helper message 15, its admitted reply as app message 13, and three call codes.
   The version goes from 13 to 14. This rests on "Version skew".
9. An unsafe undeclared run's header names the run as an unverified script. This rests on ADR-09 and M3's header check.

## Checks left to the user

- M2: the user looks at the pane in light and dark mode and confirms the layout and the chrome's contrast with
  permission prompts. The coordinator views the UI-test screenshots first.
- M4: the user runs a bash script and a Janet script that ask forms in the running app and confirms the flow. A UI test
  covers the same flow first.

## Milestones

### M1: Form spec and validation

Commit: "Read and check script-asked form specs". It carries the code, the proposal's DONE status and As built block,
and this report.

M1 adds a new pure target, `QuestionForm`. It holds the form model, the strict spec reader, the caps, the field
validation, and an ECMA-262 `pattern` parser that emits ICU syntax. The reader widening was already built, so M1 only
verified it.

Checks: `make fmt-check`, `make lint`, `make check`, `scripts/swiftpm-offline-check.sh`, `make build`, and
`make test-helper-sandbox` pass. `caffeinate -dimsu make test-package` ran 3031 tests with 0 failures and 10
existing skips. A scoped address-sanitizer run of the new fuzz test passed 20,000 mutations. `proposals.py check` is
clean. The coordinator reran the 36 QuestionForm tests and `make fmt-check`, and both passed.

Test cost: the four new test files run in about 1.2 seconds together. About 0.7 seconds of that is the
catastrophic-pattern test, which waits in real time on purpose. It proves a stopped match uses no CPU afterwards.

Best guesses, all in the proposal's 2026-11-21 Decision Log entry:

1. A `table` block is `{"block": "table", "rows": {...}}`, in spec order. This rests on M4's rule that a table's pair
   keys stay strings. If it is wrong, only the reader changes.
2. `notice.level` defaults to `info`. A `text` question is single-line unless `multiline` is true. `other` applies to
   `choice` only. A default must pass its question's rules, except `pattern`.
3. Duplicate button ids and an empty `actions` array refuse. So do a form with only `cancel` buttons, and a `cancel`
   button with `validates: true`.
4. `pattern` refuses lookbehind, since ICU allows only bounded lookbehind. Its property table holds the general
   categories, ECMA-262's binary properties, and 13 common scripts. Other scripts refuse for now. Widening is
   additive.
5. The caps are a 32 KiB spec, 64 items, 8 buttons, and 64 choices of 256 bytes each. A `string` answer gets 1024
   bytes and a `text` answer 4096. A file answer holds 16 paths of 1024 bytes. Number literals have 20 digits and an
   exponent within 20. A pattern has 512 bytes, 2048 nodes, 16 nested groups, and repeat counts up to 1000. A check
   has a 0.5 second limit and a 4096-unit input cap. The reader refuses a spec whose worst-case result exceeds one
   reply, measured with the reply encoder.
6. The spec reader uses `StrictJSONReader` directly, not `StrictJSON.members`. `members` throws a `controller.json`
   error, and the spec's errors name its own fields.
7. An empty string or an empty list counts as unanswered and returns `null`.
8. The model's `ended` outcome has no script value. M3 delivers ended as a failed wait, as "Lifecycle and results"
   says.

Review findings:

- ICU failing mid-match read as "no match" (PLAUSIBLE). The trace confirmed it. A probe pattern on a 4094-character
  input returned no match after about 7 ms, though the input matches. Fixed: a match that does not run to completion
  is "could not check". The new regression test was not run on the unfixed code. The probe is the evidence that it
  fails there. The test pins this pattern on this ICU version.
- The `ended` outcome encoded a script-visible `{"outcome": "ended"}` record. That contradicted the proposal, which
  fails the wait instead. Fixed: `ended` has no script value.
- The "never cut short" guarantee rested on M2's widgets (PLAUSIBLE). Fixed: the result layer enforces every cap
  itself, for any input. That includes a `validates: false` submit.
- Two test-only hooks, `peakInFlight` and `icuText`. Fixed: removed, and the tests prove the same contracts through
  behavior. The one-check-in-flight rule is now structural, from the field's serial queue.
- The M1 bullet on `\p` names was stale, and the Decision Log lacked the cap numbers and other guesses. Fixed in place.
- Four comment-craft findings. Fixed.

`adr-impact` found no conflicts. It noted one advisory item outside the diff: the proposal still cites ADR-09 in three
places, and ADR-14 now supersedes ADR-09.

Freeze: one hunk with origin `other`, in UTERM-004's References. Another session added the ADR-14 line. It is left for
the user.

Bugs found: none outside the milestone's own code. ADR candidates: none. Deviations: none.

### M2: Questions applet UI

Commit: "Show script-asked forms in a Questions pane". It carries the code, the proposal's DONE status and As built
block, and this report.

M2 adds an AppKit `QuestionsApplet`. Each requester has a tab, and the tab bar shows even for one tab. A form shows a
uniterm-drawn requester header, then the form's title, its numbered questions and content blocks, and its buttons.
Widgets enforce M1's caps. Return, Escape, and the button roles follow "Buttons". A field's error shows on leaving it
or on a try to submit. A new or reused tab takes focus. The pane offers an in-process API that M3 calls. A debug-only
hook lets UI tests open forms from fixture files.

The commit between M1 and M2, "Order UTERM-019 M3 after UTERM-042's tab menu", is another session's. It is not part
of this run.

Checks: `make fmt-check`, `make lint`, `make check`, `scripts/swiftpm-offline-check.sh`, `make build`,
`make test-helper-sandbox`, and the UI test build pass. `caffeinate -dimsu make test-package` ran 3086 tests with 0
failures and 10 existing skips. `proposals.py check` is clean.

The coordinator ran `QuestionsUITests` twice. The first run passed 21 of 22. `testEveryAnswerTypeReturnsItsShape`
failed with EPERM, writing its picked file into the app's socket folder. After the fixes, all 22 passed. Neither run
left a crash report.

The coordinator viewed the screenshots of one form and of two forms, in light and dark. The header band, the tab bar,
the numbered questions, the notice block, the radios with an Other field, and the disabled primary button all render
as intended. Focus sits on the first field. The user's own look at the pane is left to the user.

Test cost: the new package test files run in about 1 second together. About half of that is the first AppKit window
in the process. `QuestionsUITests` runs in about 105 seconds for 22 tests.

Best guesses, all in the proposal's 2026-11-21 Decision Log entry:

1. A restored or reopened Questions pane with no tab shows an empty state, "No questions are open". It does not close
   itself. A window whose layout holds only a Questions pane would otherwise close at restore. "The Questions pane" and
   the M2 check were amended in place.
2. The tab cap is 8. It counts only open forms against a newcomer, and the host may pass another number. The eviction
   pick is built and tested in a pure `QuestionsBook`.
3. The API for M3: `open(spec, for:resolved:)` returns opened or busy, and the callback gets a `FormOutcome` once.
   `end(requester:)` resolves an open form as ended and closes its tab. `discard(tab:)` resolves it as ended and keeps
   the tab. `askingPaneDidClose(forRequester:)` updates the header. Closing a pane or a tab dismisses open forms.
4. Widget thresholds: a `choice` shows radios for 5 entries or fewer, and a pop-up above that. A `multi` shows
   checkboxes up to 8, and a scrolling box above that. A `boolean` with no default is a checkbox with a mixed state.
5. A question caption reads "Question N of M · Required" or "· Optional".
6. The `questions` type has no remote control, no launcher entry, and no New Tab.
7. When the first control refuses focus, the keyboard goes to the form panel. Return and Escape then still reach the
   form.
8. The arrival status line reads "<requester> is asking you a question." It carries no script text.

Deviation: the plan named the create factory too. The implementer left the `.hosted` create case out. A script's layout
request of kind `questions` would otherwise build an empty Questions pane. M3 places the applet itself. The Decision Log
records it.

Review findings:

- The As built block did not say who looks at the pane in light and dark. Fixed: it says the coordinator viewed the
  screenshots, and the user's look is left to the user.
- `end` after the pane closed called `appletDidExit` on a closed applet (PLAUSIBLE). The trace confirmed it. Fixed:
  every entry point is a no-op after close, and close empties the book. A test covers it.
- A VoiceOver user could not reach the try-to-submit on a disabled button, and shown errors were not announced
  (PLAUSIBLE). The trace confirmed it. Fixed: an accessibility action runs the try. A shown error becomes the field's
  help, and a failed try posts an announcement.
- The color well's Escape monitor acted in any window (PLAUSIBLE). The trace confirmed it. Fixed: it acts only in the
  color panel or the form's window.
- Return and Escape were swallowed when the form had no matching button. Fixed: they pass up.
- A comment would go stale at M3. Fixed.
- Two tests covered the same eviction rule. Fixed: the applet-level test now covers the tab leaving and its panel being
  freed. A new test checks that a closed tab and a closed pane free their panels.

`adr-impact` found no conflicts. It noted two weaker candidates: closing a pane dismisses an open form without asking,
and the applet is program-only. Neither passes the ADR bar. The proposal already records both.

Freeze: only the UTERM-004 hunk with origin `other`. `spec/proposals/UTERM-043-pause-controllers.md` is modified in the
working tree by another session. The run leaves it alone.

Bugs found: two in the milestone's own new code, both fixed before commit and covered by tests that failed first. ADR
candidates: none.

### M3: The ask power and the form calls

Commits:

- "Pin the bound on calls held during a peer's full check", a separate bug triage that lands before M3.
- "Let scripts ask the user a form and wait for the answer", which carries the code, the proposal's DONE status and As
  built block, and this report.

M3 adds the `ask-user` permission kind and the `open-form`, `wait-form`, and `discard-form` host calls. It adds the
question-only begin and bumps ScriptWire to version 14. A host-side handle table holds each form's result, as ADR-11
requires. The header names each requester as the transport established it. The window opens the form in its Questions
pane, or in a split beside the asker. The asking pane shows a badge until the form resolves.

Other sessions committed these on the branch between M2 and M3. They are not part of this run: "Schedule UTERM-041,
UTERM-042, and UTERM-019", "Resume UTERM-043 now that its revisit hook fired", "Schedule UTERM-032 and the presentation
chain", and "File the bug where calls held during a peer's full check grow without bound".

Checks: `make fmt-check`, `make lint`, `make check`, `scripts/swiftpm-offline-check.sh`, `make build`,
`make test-helper-sandbox`, the UI test build, and a scoped address-sanitizer fuzz of the wire, controller, policy, and
declaration readers pass. `caffeinate -dimsu make test-package` last ran 3150 tests with 0 failures and 10 existing
skips. `proposals.py check` is clean.

The coordinator ran `QuestionsUITests` and `QuestionsWireUITests` five times:

1. The first run stopped at start, because the Automation Mode prompt was cancelled while the user needed the screen.
   It ran again once the user was done.
2. 24 of 25 passed. `testAnErrorShowsOnLeavingTheFieldAndClearsAtOnce` failed, because a second focus call ended a
   field's editing.
3. With a guard in place, `testEveryAnswerTypeReturnsItsShape` failed, and it failed again alone. The open panel showed
   its go-to field somewhere the test did not look. The keyboard sat in the panel's own `PathTextField`.
4. After the root fix in the applet, the same file-panel failure remained.
5. After the test's file picker was fixed, all 25 passed.

No crash report came from the UI runs. The wire test proves the real path: a declared script asks, the review is
answered, a split opens beside the asker and takes focus, the badge shows and clears, and the answer prints.

Test cost: the 53 new M3 package tests run in about 1.5 seconds together. The two UI classes run in about 128 seconds
for 25 tests.

Best guesses, all in the proposal's Decision Log. The first two deserve the user's review.

1. Every connection that is not a declared or package run may ask without a prompt. That covers a bare terminal
   session, a REPL, a granted connection, and an unsafe undeclared run. A declared run must declare `ask-user`. The M3
   checks need a REPL and an unsafe run to ask, so this is the reading that meets them. "The ask power" named only the
   bare terminal-session caller, and it is amended in place. `adr-impact` names this tier choice as an ADR candidate.
   See "ADR candidates" below.
2. A Questions pane split beside a member of an owned group joins that group's content but not its members. The
   owner's next layout of the group is then refused whole, until the Questions pane closes. A split the user makes
   there gets the same refusal, and ADR-15 says a program's operation behaves as the user's. The refusal outlasts the
   answer: a run's resolved tab stays until the run ends. The refusal message names the Questions pane and says what to
   do. The M3 check on owned groups was reworded to match, as a run best guess. If the user wants the owner's layout to
   proceed around the pane, the layout engine needs a rule for it.
3. `ScriptFailureKind.ended` is a new wire failure kind, 8. M4's exit code 4 needs it.
4. `uniterm/open-form`, `uniterm/wait-form`, and `uniterm/discard-form` join the Janet module now, with the spec as JSON
   text. M4 wraps them.
5. Header names: a package shows its verified ID. A declared file shows "<id> (declared file)". An unsafe undeclared
   run shows "<file> (unverified script)". A REPL shows "REPL in Pane N", a granted connection shows "<exe> (PID n),
   granted Pane N", and a bare caller shows "Terminal session in Pane N".
6. Each connection holds 32 result slots, the text viewer's cap. A new slot drops the oldest settled one, and handles
   are never reused.
7. A terminal session's resolved tab stays until its shell ends. A run's or a connection's tab closes when it ends.
8. A REPL stop fails only the pending wait. The form stays open until the helper discards it. M4's Janet wrapper must
   discard on unwind.
9. The question-only session is admitted after the full check, with no review. Any call but a form call ends the
   connection as a protocol violation.

Review findings:

- The proposal text was narrower than the code on the ask power, the question-only session, and the REPL stop. Fixed:
  amended in place.
- The owned-group refusal blamed "a pane the user split off". Fixed: it names the Questions pane. Traced: it outlasts
  the answer. Recorded for the user.
- `wait-form`'s recheck skipped the ancestry check (PLAUSIBLE). The trace confirmed it. Fixed, with a test.
- Stopping the host left forms on screen with no one to answer them (PLAUSIBLE). Fixed: `stop()` ends them as authority
  ending does. A test covers it.
- The triage test could pass with the in-flight wait removed. Fixed, and a mutation run showed the test fails without
  it.
- Comment-craft and test-naming findings. Fixed.
- A REPL's form can be left open after a stop. Noted for M4.

`adr-impact` found no conflict it could confirm.

- It flagged that ADR-11 names a completion event, which M3 does not send. The proposal already settles this: "wait-form
  is the form's completion mechanism", and ADR-11's event serves event-stream callers. Recorded as advisory.
- It noted that the proposal still cites ADR-09, which ADR-14 supersedes. This is advisory.
- It rated the owned-group refusal as plausible friction with ADR-15, which is only proposed. This is advisory, and
  best guess 2 covers it.

ADR candidates:

1. Which callers a new power that controls no pane, such as `ask-user`, passes without a prompt. `adr-impact` says this
   sets a tier that later powers will copy. Against the bar, it cuts across the system and would be hard to reverse once
   scripts rely on it. ADR-14 says separate powers need explicit grants, but it does not say what a user's own session
   may do without one. It is recorded as `Undecided` in UTERM-022's Decision Log.
2. `adr-impact` also named two weaker candidates. One is an ask that narrows an owner's later layout. The other is the
   `ended` failure kind. Both are specific to this applet, or already covered by ADR-11 and ADR-15. They fail the bar.

Bug triage: "Calls held during a peer's full check grow without bound" does not occur. The connection stops reading
once 8 calls wait for an answer, and held calls have no answer, so the in-flight limit bounds the held list. The bug
file is `not-reproducible`, and a flood test pins the bound.

Bugs found in M3's own work: two, both fixed before commit. One is the ancestry gap in the wait recheck. The other is
the non-idempotent focus that showed an error before the user typed. A test covers each.
