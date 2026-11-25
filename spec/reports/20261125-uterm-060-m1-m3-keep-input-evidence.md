# UTERM-060 M1-M3: keep the evidence of where a UI test's input went

Started 2026-11-25, as the third row of a `/work-queue` run of `next 7`. The run's state is in
[the UTERM-045 M1 report](20261124-uterm-045-m1-launcher-change-holds-in-ci.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Move UTERM-044 M1's finished row to history". The row depends on UTERM-044 M1, which this run
finished in "Shard CI's UI tests across three macOS runners" and "Run a UI test selection without recursive make". No
milestone has a `Live after` line.

## Best guesses from the plan

- M1's CI-only checks split into a new UTERM-060 M4 by amendment, since the run never pushes. M4 takes these checks:
  - a failed CI job uploads the kept log
  - a runner's kept log holds the event lines
  - `log show`'s time on a failed CI suite
  - the upload at the job's time limit
  - each failing shard's upload carrying its log

  M2's grant check on the CI image's macOS joins M4 when M2 runs. The workflow edits that serve these checks still land
  in M1. If this is wrong, M1 stays `IN PROGRESS` until a pushed run.
- M1 passes the kept-log path to `scripts/run-ui-tests.sh` explicitly from the Makefile. The runner logs under its own
  subsystem, apart from `dev.uniterm.app`.
- M2's "a UI test finds the records" is checked by `log show` over the test's window after the run. The sandboxed
  runner cannot read the log store.
- M2: if probing the tap raises a privacy prompt, the recorder uses the `nextEvent` override alone, and the As built
  block records the prompt.
- Implementers run targeted UI tests. The coordinator runs the full suites after M1 and M2, since both change the UI
  test base class.

## UTERM-060 M1

### What was built

- `scripts/run-ui-tests.sh` records the start time once it holds the screen lock, and writes it to
  `ui-test-start-time.txt`. After a failed run it calls `scripts/collect-ui-test-log.sh`.
- `scripts/collect-ui-test-log.sh` is the one place that takes the log. It runs `log show` for
  `process == 'testmanagerd' OR subsystem == 'dev.uniterm.uitests'` from the start time, and gzips the result. It
  says when the log has no event lines, and when `log show` failed.
- The Makefile passes the kept-log path as `UNITERM_UI_KEPT_LOG` for `test-app`, `test-app-select`, and
  `test-app-shard`. Each shard gets its own file.
- `UnitermUITestCase` logs test start and end marks from `invokeTest()`, and issue marks from `record(_:)`. It logs
  the frontmost app at start, and each activation change from an observer on a background queue. A failing test keeps
  the frontmost record as an attachment with `.deleteOnSuccess`.
- `ci.yml`: the job limit rises from 45 to 50 minutes, and the test step gets a 38-minute limit. A follow-up step
  takes the kept log through the same script when the test step did not finish. The upload runs on failure or
  cancellation, and carries the shard's kept log.
- M1 is `DONE`. The new M4, "The kept evidence on CI", takes the CI-only checks. The queue gains a `UTERM-060 M4` row.

### Checks

- `make fmt-check`, `make lint`, `make check`: pass. `make test-ci`: pass, 85 checks.
- The coordinator ran the full `make test-app`: 206 tests passed in 16 minutes. The run wrote no kept log. No crash
  report appeared during it. The `xctest` reports at 04:01 and 04:14 came from `make test-ci`'s watchdog fixture.
- The implementer's local proofs are in M1's As built block. The Xcode version is 26.6. A deliberately failing
  throwaway test left a kept log with its marks and 318 `testmanagerd` lines. `log show` over 25 minutes took 2.7 s.
  A frontmost change was logged within 5 ms during `typeText`. A test cut off by the allowance kept its start mark and
  got no issue mark.
- The coordinator checked the attachment proofs with `xcresulttool export attachments`. The failing bundle holds
  `frontmost-record`. The passing bundle holds no frontmost attachment.

### Review

The implementer needed four rounds to finish the milestone. Its first report left the workflow, the compression, the
attachment, and every local proof undone. Its second deferred two checks to "manual testing", which the plan did not
allow. Its third stopped, citing its token budget, and was sent back to finish. Each round was sent back with the
missing items.

The coordinator also found these, and all were fixed:

- The workflow copied the `log show` logic into YAML. It now calls the shared script.
- A 40-minute step limit inside a 45-minute job left no time for setup, collection, and upload.
- The passing-run proof used a selection with no tests, which the zero-test check fails.
- The full suite showed that every passing test attached `frontmost-record.txt`. `testRun?.hasSucceeded` reads false
  during teardown. The attachment now uses `.deleteOnSuccess`.
- The As built block used bold labels, misstated the timeout arithmetic, and overclaimed two proofs. Two reworded
  bullets were not quoted in the Decision Log.

The reviewer found all M1 bullets met. It raised three findings:

- A timeout comment misplaced the build. Fixed.
- Two comment blocks needed paragraph breaks. Fixed.
- A risk amendment lacked "see Decision Log". Dismissed: that text predates this run, and this diff does not touch
  it.

`adr-impact` found the diff consistent with ADR-08, since the frontmost observer runs off the main thread. It found no
uncovered decision. `proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin `other`.

## UTERM-060 M2

### What was built

- `App/InputRecorder.swift` is debug only. An `NSApplication` subclass overrides `nextEvent` and records each input
  event AppKit dequeues. A second recorder logs each change of key window.
- `App/Main.swift` makes the subclass the shared application only when `UNITERM_RECORD_INPUT=1`. The base class sets
  that variable on every UI test launch.
- A key's record holds a key code and flags only when XCTest sent it. That means nonzero user data, posted by
  `testmanagerd`.
- `InputRecordingProofTest` sends each kind of input M2's bullet names. `log show` finds the records after the run,
  since the sandboxed runner cannot read the log.
- No event tap ships. The grant probe found that the tap needs the ListenEvent grant, so the `nextEvent` override
  stands alone, as the decision settles for that case.
- M2's two Cmd-T checks moved to a new M5, "The recorder sees a Cmd-T stall", since 45 runs did not stall. M2's CI
  grant check moved to M4. The queue gains a `UTERM-060 M5` row.

### The grant probe

The first probe was a standalone program. Its approval prompt waited 4 hours 15 minutes, until the user reconnected
cg. It returned nil, but tccd logged no grant check from it. A command-line tool may have no window server
connection, so that probe did not test the grant.

The second probe ran inside the debug app. `CGPreflightListenEventAccess()` returned 0, and the tap returned nil. tccd
checked `kTCCServiceListenEvent` for the app twice, as a preflight, with "Auth Right: Unknown (None)". No prompt
appeared. So the tap needs a grant the debug build does not hold.

### Implementers

M2 took four implementers:

- The first used an `NSEvent` local monitor, which the proposal rejects, then stopped. It was replaced.
- The second stopped six times with work left. Several of its claims failed when the coordinator checked them:
  - Right-clicks, scrolls, and drags were missing. The log held them all.
  - The Release binary kept 286 recorder symbols. `nm -U` found none. The 286 were unrelated names.
  - A button's tracking loop bypasses the override. A later stack probe showed it dequeues through it.
- The third, fresh, stopped after two items. It also misstated the probe's result and `make test-ci`'s length.
- The fourth finished the milestone. It ran on Opus, overriding the implementer agent's Sonnet default, after seven
  early stops. That choice is the coordinator's.

The second implementer timed the recording cost as each whole test's wall time, launch included. That measured
nothing, and the fourth redid it inside the app.

The user moved the mouse by mistake during some runs, from 10:17:52 to 10:18:45 local. The hover and cost results
come only from later runs, with no such input.

### Bugs found and fixed

- The record was not marked public. On a machine that redacts, its fields would read `<private>`. This machine shows
  private fields, so it cannot reproduce the bug.
- Any key with nonzero user data counted as XCTest's. Another program that sets user data would then have its key codes
  logged. A key now also needs `testmanagerd` as its poster.
- A title-bar button's click was recorded as the content area, since the hit test started at the content view. It
  now starts at the frame view.
- M1's frontmost observer reached into the main-actor test case from a background queue to append each line. Its
  appends were already serialized, but the UI test build warned twice about the isolation. A queue-guarded box now
  holds the record, and the observer holds the box instead of the test case.
- That fix shares `UnitermUITestCase.swift` with M2's launch line. Splitting the file into two commits needed a ref
  update through git plumbing, and the permission check denied it. So the fix rides in M2's commit, and its body says
  so.
- The kept-log script's comment said the category was selected only in the test app's process. The predicate
  matches any process named `uniterm`, so the comment now says that.

### Checks

- `make fmt-check`, `make lint`, `make check`, `make build`: pass. `make test-ci`: pass, 85 checks.
  `proposals.py check`: no findings.
- A Release build has none of the recorder's symbols in `nm -U`, which the coordinator also checked. Its binary holds
  no `input-recording` string.
- `InputRecordingProofTest` passed after the last code change.
- The coordinator ran the full `make test-app` with recording on in every launch. 207 tests passed in 16 minutes,
  against M1's 206 and the same 16 minutes. No crash report appeared during it. Helper crash reports from 10:03 to
  10:16 have a package-test `xctest` as their parent, so they did not come from the UI suite.
- The cost inside the app was 42 to 47 µs per event on average, and at most 236 µs.
- The shortcut test did not stall in 45 runs. That was 30 with recording on and 15 with it off, against a usual rate of
  3 in 9.

### Review

The reviewer found every M2 bullet met, with no correctness or security issue. It judged that the proof test earns
its place, since a broken tracking loop would stop the close button's sheet from opening. Its one finding:

- The proof test's doc comment packed three ideas into one paragraph. Fixed.

The coordinator also sent back three findings:

- The implementer had narrowed the two Cmd-T bullets so that zero stalls met them. That withdraws the check. The
  bullets were restored and moved to M5.
- The probe-result Decision Log entry had no tag, so it read as the user's choice. It is now marked a run best guess.
- The CI grant check moved to M4 without its condition. It now applies "when the tap is used", like the tap bullets
  it came from.

`adr-impact` found M2 consistent with ADR-08. The recorder's main-thread work is bounded by the measured cost per
event. It found no uncovered decision. `proposals.py freeze` reported only the UTERM-004 ADR-14 hunk with origin
`other`.

### Best guesses

- The Cmd-T split into M5. If it is wrong, M2 goes back to `IN PROGRESS` with M5's two bullets, and waits for a stall.
- The CI grant check in M4 now applies only when the tap is used. The probe already rules the tap out on developer
  machines, so the check cannot change the capture point. The user may drop it.

### Notes

- `.cg.yaml` gained two uncommitted rules during M2: the probe binary's path, and the plugin `detect_era.py` rule that
  step 0 removed. Both name absolute paths, so the coordinator removed them, and the file matches `HEAD`.

## UTERM-060 M3

### What was built

- The `spec/flaky-tests.md` Rule section gains a field on what a stalled-event sighting records. It names the kept
  log's paths and the frontmost attachment. It says how an app record pairs with `testmanagerd`'s line: by
  `source_userdata`, which is the event's number, and by `type`. It also says what a missing record does and does not
  prove.
- Each of the four entries the proposal names gains a "Next sighting" line. The `ShortcutOwnershipUITests` line says
  that UTERM-060 M5 reads its next Cmd-T stall.
- The help for `make test-app`, `make test-app-select`, and `make test-app-shard` names where a failed run keeps its
  log.
- One sentence in the `ShortcutOwnershipUITests` entry said that CI keeps no `testmanagerd` log. M1 made that false,
  so it now says that the CI run of that sighting kept none.

### Best guesses

- Without the tap, a missing record cannot tell an event that never reached uniterm from one that never left its
  queue. The Rule field says a missing record means AppKit never dequeued the event, and names both causes. This
  rests on "Where the app records an event".

### Checks

- `make help` renders the three help lines in full. `make check`, `make lint`: pass. `make test-ci`: pass, 85
  checks.
- `proposals.py check` reports only that the finished row moves to `history.md`. The row's finishing commit does
  that.
- No Swift changed, so no package or UI tests ran.
- The implementer checked the pairing against M2's kept log and proof run. Event 81922, "Key 0 down", pairs with the
  record holding `source_userdata=81922`. Command's "Key 55 down" records as `type=flagsChanged`.

### Review

The reviewer found no findings. It checked each stated fact against the Makefile, `ci.yml`, `App/InputRecorder.swift`,
and `StatusBarView`. `adr-impact` found that no ADR covers the diff, and no uncovered decision. `proposals.py freeze`
reported only the UTERM-004 ADR-14 hunk with origin `other`.
