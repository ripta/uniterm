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
| UTERM-022 M2: Questions applet UI | QUEUED | |
| UTERM-022 M3: The ask power and the form calls | QUEUED | |
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
