# UTERM-008 M3: map pins from programs work-queue run

Started 2026-11-20. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-008 M3`, from `spec/proposals/UTERM-008-map-viewer-applet.md`. M3 lets an exec driver and an authorized
remote caller place pins on a map pane through the map's command schema. The driver also gets the map's click and
selection events. The specs live in the code repo, so every commit below is in this repo, on the `agent/petunia`
branch.

## Run state

The run's base and the row's base are both the commit "8< --- snip ---" that follows "Let UTERM-025's slide pane and
UTERM-026's zoom follow a layout's focus". Step 0 fetched `upstream/main`. The branch already sat on it, so no rebase
ran.

The row is finished. UTERM-008 is `implemented`, the index says so, and the row moved from `queue.md` to the end of
`history.md` in "Mark UTERM-008 implemented now that its program pins are in".

The row's one dependency, UTERM-004 M3, is met. No milestone carries a `Live after` line. Nothing is held, blocked, or
skipped, and no work is stashed.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-008 M3: Pins from programs | DONE | See "Commits" under M3 |

The run is done. Its commits, in order:

1. "Let programs place pins on a map pane"
2. "Clear the map's program pins all at once until the pin list clears one layer"
3. "Mark UTERM-008 implemented now that its program pins are in"
4. "Prove a click on the empty map reaches a map's driver"
5. "Close the UTERM-008 M3 work-queue report"
6. "Drive a map's program pins through reopen and relaunch in the real app", which also carries this report's last
   amendments

## The user's choice in the plan

M3 had a check that a map with a live exec driver reports `isRunningSomething`, so closing it asks first and names the
driver. That conflicts with the user's rule against confirmation dialogs. Reopening the pane brings back its program
pins and offers Run. The image viewer also supports exec drivers and closes without asking. The user chose no ask: the
map's `isRunningSomething` stays `false`, and M3's check is amended to say so.

## Run-level best guesses

1. The per-layer pin cap is sized to the 1 MiB exec frame, as "Where pins come from" says "one UTERM-004 frame". It is
   the smallest of the frame bound, the decoded value bound, and the retained-bytes bound, with every UTF-8 byte
   escaped. If wrong, only the cap constants change.
2. A script's `uniterm/send-command` carries at most 32 KiB of arguments, so a script cannot send a worst-case full
   layer. The ScriptWire limit stays, since raising it would add scope. An oversized call must fail before any effect.
   This deserves the user's review first.
3. A command that names no layer uses the default layer for every caller, not only exec drivers. The proposal was
   silent for remote callers. If wrong, only remote validation changes.
4. A command whose `source` names the file layer is refused. This leaves room for UTERM-016 M4's file-layer target.
5. Program pins are cleared from the UI by one registry command that clears every command layer, unless the pin list
   already offers more. UTERM-016 M4 owns the pin-list work.
6. The published schema is the `summary` and `example` fields in code, as the image and text viewers do. A test checks
   each example and each emitted event against the schema.
7. "Where pins come from" cites ADR-09, which ADR-14 supersedes. The citation is corrected as a fact.
8. The schema starts at 1.0, as the image viewer's did.

## UTERM-008 M3: Pins from programs

### Commits

All in this repo. "Let programs place pins on a map pane" carries the milestone, its review fixes, the proposal edits,
and this report.

### What was built

The map adopts the applet command hook at schema 1.0 and declares every control combination. The commands are `add`,
`remove`, `clear`, `set-layer`, and `set-region`. The events are `map-clicked` and `pin-selected`. The pure layer store,
caps, and sanitizer sit in `GeoData/CommandPins.swift`. The applet side sits in `MapViewerApplet+Remote.swift`. Command
layers ride in the undo-only part, marked "From an earlier run" after a reopen until a command writes them. The payload
keeps only `commandLayerCount`, which drives the relaunch notice. A File menu command, Clear Program Pins, clears every
command layer. `isRunningSomething` stays false, as the user chose.

### Checks

- `make lint`, which includes `fmt-check`: pass.
- `make check`: pass.
- `caffeinate -dimsu make test-package`: 2929 tests, 10 skipped, 0 failures, after the review fixes.
- `xcodebuild build-for-testing`: pass.
- UI tests, run by the coordinator through `cg_run`. A probe of one map test passed in 19 s. `MapViewerUITests` and
  `ExecPaneUITests` passed before the review fixes, with 11 tests and 0 failures. `MapViewerUITests` passed again after
  them, with 9 tests and 0 failures.
- The coordinator viewed the "driver-pins" capture. The driver's two pins show in the first command layer's peach
  accent, over the San Francisco Bay map. The status bar reads "Driver perl is running."
- The crash folder holds no uniterm report from the UI runs. It holds `ImageDecoderHelper` reports at 20:29, during the
  package run. The same reports appear from an earlier package run at 00:25, before this run began. They are not this
  milestone's.

### Test cost

Each new test class was run alone, after a build.

| Test class | Tests | Wall time |
|---|---|---|
| `CommandPinsTests` | 11 | 0.023 s |
| `MapRemoteTests` | 22 before the review fixes | 0.46 s |
| `MapFrameBudgetTests` | 4 | 0.68 s |
| `MapExecWindowTests` | 3 | 1.0 s |

`MapExecWindowTests` starts a perl driver in each test.

### Best guesses beyond the plan

1. The event names are `map-clicked` and `pin-selected`, in kebab case like the commands. The proposal's prose had
   spaces.
2. `set-region` takes no `layer` or `source`, since the region is not layer state.
3. The arguments are a `coordinate` object of `latitude` and `longitude`, and a `center` plus a `span` of
   `latitude-delta` and `longitude-delta`.
4. Command layers take accents from layer-order index 1, since the file layer holds index 0.
5. A pane holds at most 13 layers and 2500 pins. 13 layers plus the file use each of the 14 accents once. The
   per-layer cap is 624 pins. The frame bound is the tightest, at 1677 bytes per worst-case pin.
6. IDs, layer names, and glyphs are capped at 64 UTF-8 bytes. Labels are capped at 128.
7. `remove` of an absent ID replies `removed: false`. `clear` of an absent layer makes no layer.
8. Cap errors are `refused`. Validation errors are `bad-argument`.
9. The first click of a double click counts as a click. Telling the two apart would delay every click.
10. Selecting a cluster fits the map to its members by the same rule as Zoom to Fit Pins. `showAnnotations` crashed in
    a test.
11. A reopen snapshot with any invalid value is dropped whole. The pane then counts as rebuilt, and the notice shows
    when the count is above zero.
12. A program's `set-region` is not saved with the pane, since only a user gesture saves a region.
13. The script wire cuts a call past 32 KiB at the bound instead of refusing it. The cut call fails before any effect.
    It fails as a bad argument, or as a protocol error on the connection when the cut lands inside a multibyte
    character. An overflow of only trailing whitespace runs unchanged. A script can send about 300 ordinary pins per
    call, not the 624-pin cap.

### Review findings

The reviewer found no plan-conformance gap. `adr-impact` found no conflict and no supersession. It checked ADR-03,
ADR-05, ADR-06, ADR-07, ADR-08, ADR-11, ADR-13, and ADR-14.

1. A press on MapKit's zoom control or compass counted as a click on the empty map. PLAUSIBLE, traced, fixed. The
   implementer reasoned that macOS shows both controls by default. The final review's probe found their defaults off,
   and the app turns none on, so only the attribution label shows today. The fix still guards the controls if they are
   turned on. The click test now rejects any `NSControl` and the MapKit control classes by name. The new test was not run against the unfixed
   code, so it pins the fix. The diagnosis stays unresolved. A live MapKit legal link was not hit-tested.
2. A restored selection flag could go stale when MapKit sent no select event, and it held a removed pin. PLAUSIBLE,
   traced, fixed. The flag is now weak and cleared on deselect. The new test was not run against the unfixed code, so it
   pins the fix. The diagnosis stays unresolved.
3. The proposal said an oversized script call fails as a bad argument. A cut inside a multibyte character fails as a
   protocol error instead. CONFIRMED, fixed in the M3 check, "Where pins come from", and the As built block.
4. Two tests proved the same no-effect contract for an oversized script call. Fixed. The window test owns it, and the
   frame-budget test now proves only that a full layer of ordinary pins exceeds the script bound.
5. A click entry point was documented as test-only. Fixed. It is the real path, and the event handler calls it.
6. Two proposal lines broke the file's width. Fixed.
7. A subtitle argument in `add` was always nil. Fixed.

`adr-impact` raised one marginal candidate: program output rides in the undo-only part, survives a reopen, and is
dropped on a relaunch. Not recorded. The Decision Log already declined a near twin on 2026-11-03, since spooling is each
applet's own decision.

### For the user

- `proposals.py freeze` reports a hunk in `spec/proposals/UTERM-004-control-and-trust.md` near line 1646. It adds an
  ADR-14 reference line. Its origin is `other`, so this run did not make it, and the run left it alone.
- Left to the user's eye: the "From an earlier run" callout subtitle, the pin callout, and cluster expansion in a live
  map. The UI test cannot select a pin, since MapKit pins are not accessibility elements. The status segment was
  checked later in the run. See "Final review".

### Bugs

None found.

## Row review

The row review covered the range from the run's base to "Let programs place pins on a map pane". The reviewer found
no correctness or security issue, and every M3 check traced to code and tests. The fixes landed as "Clear the map's
program pins all at once until the pin list clears one layer".

1. "Where pins come from" still promised that the user can clear any layer from the map's UI. M3 shipped one command
   that clears every program layer. PLAUSIBLE, fixed by amendment as a work-queue best guess. The bullet now says the
   user clears the file layer and all program layers. A per-layer clear comes with UTERM-016 M4's pin list, which
   already plans a Clear action for each program layer. If wrong, M3 needs a per-layer control before UTERM-016 M4.
2. A window test slept a real 200 ms three times. Fixed. A refused hello ends the driver's channel before it can
   deliver any command, so the test's wait for that end already proves the absence. The class ran in 1.13 s alone
   before and 0.50 s after.
3. The published `map-clicked` summary read "sends this event never". Fixed to "does not send this event".

Checks after the fixes: `make lint` passed, `make check` passed, and `caffeinate -dimsu make test-package` exited 0 in
227 s. `proposals.py check` reported only the two row-finish findings. No UI test ran again, since the fixes touched no
UI path.

`adr-impact` found one PLAUSIBLE tension. ADR-05's Consequences say "a close that would end running work asks the user
first." A map with a live exec driver now closes without asking, by the user's choice in this run's plan. The image
viewer and data viewer already behave this way. The run left ADR-05 unchanged. The user may want it clarified.
`adr-impact` also named two candidates below the ADR bar: applet schema versions accept only their own major, and the
script wire cuts a call at 32 KiB. Neither was recorded.

## Final review

The final review covered the run's three commits, from the run's base through "Mark UTERM-008 implemented now that
its program pins are in". It was also the run's ADR review. The range adds and edits no ADR. The freeze check found no
UTERM-008 hunk. The reviewer found no blocking issue. Its two PLAUSIBLE findings were traced, and neither was
confirmed. The tests from the traces landed as "Prove a click on the empty map reaches a map's driver".

1. Matching MapKit's chrome by class name could reject the map's own surface, or let a chrome view through. Not
   confirmed. A probe walked a real `MKMapView` with every control turned on. At the center and the four corners, the
   hit is the map itself. The attribution label, compass, scale, zoom, and pitch control each match a rejected name.
   The app turns none of those controls on. A new package test pins the names. It passes on the unchanged code by
   design. A new UI test clicks the empty map in the real app and finds the driver's "got event map-clicked" line in
   the history. It passed in the coordinator's run. The callout was not probed, since it needs a pin selected on
   screen. A later macOS could rename these classes.
2. A command landing before `start` could skip the relaunch notice. Not confirmed. Every path that inserts an applet
   starts it in the same main-actor turn. A restored exec pane runs nothing until the user chooses Run.
   `uniterm/send-command` resolves and submits within one main-actor turn.

`adr-impact` found no conflict. It confirmed the ADR-05 tension as ADVISORY. The quoted line sits in ADR-05's
Consequences, not its Decision.

### ADR candidates

`adr-impact` raised two cross-applet candidates. The first is that program output stays off the layout file. It is
the near twin of the 2026-11-03 candidate, which the user declined, so it is not recorded again. The second passes the
bar and is recorded here. UTERM-008 is `implemented` and frozen, and the freeze does not allow a new Decision Log
entry.

- ADR candidate (departs from the past): a close that ends a pane's live program does not ask first when reopen
  restores what the pane showed. Undecided. Found in UTERM-008 M3. It departs from ADR-05's Consequences, which say "a
  close that would end running work asks the user first." The map and the image viewer both rely on it. Unrecorded,
  someone following ADR-05 could add a close dialog to an exec pane, against the user's choice.

### Checks

- The trace's own checks: `make lint` and `make check` passed, `caffeinate -dimsu make test-package` exited 0 in 237 s,
  and `build-for-testing` succeeded. `proposals.py check` was clean.
- The coordinator's UI run of `MapViewerUITests`, 10 tests, had 2 failures in tests this run did not change:
  `testCommandORoutesAGeoJSONFileToTheMapAndShowsItsPins` and `testLauncherOpensAMapAndTheViewMenuSwitchesItsStyle`.
  The same class order then passed 10 of 10. Each test then passed 3 of 3 alone. Both are logged as potential flakes in
  `spec/flaky-tests.md`, with the evidence and the suspected causes. In the first, the go-to field held the previous
  test's path, which the sheet remembers, so the paste never landed. In the second, Cmd-D never landed. Both fit a
  key sent without key focus. The new tests plant no map folder, so they add no sibling path. A passing rerun does not
  prove a fix.
- A last check drove reopen and relaunch in the real app. It landed as "Drive a map's program pins through reopen and
  relaunch in the real app". `testProgramPinsReturnOnReopenAndAreAnnouncedAfterARelaunch` closes a map whose driver
  placed two pins, then reopens it. The coordinator viewed its captures. After the reopen, the two pins show as one
  cluster of 2, with a "From an earlier run" status segment and a Run button. After a relaunch, the map shows no
  pins. The history holds one info row: "1 program layer held pins last session. Restore does not run programs, so it
  is not shown." The first capture also showed the planted terminal beside the map as "could not be restored". Its
  fixture payload was empty. The fixture now plants a real terminal, and the test asserts that no such row appears.
- `testAClickOnTheEmptyMapReachesTheDriver` now waits for the driver's first pin before it clicks. The map drops events
  until the driver's hello is accepted. Its polling loop with real sleeps became an expectation.
- `MapViewerUITests` passed 11 of 11 with the new test. The full `make test-app` then ran 175 tests with 1 failure,
  `LayoutUITests.testQuitAndRelaunchRestoreTheSplitLayoutAndTheShellDirectory`: no pane showed after a relaunch.
  `LayoutUITests` then passed 21 of 21 alone. This run touched no layout code. The failure is logged as a potential
  flake in `spec/flaky-tests.md`.
- The crash folder holds no uniterm report from the UI runs. A `DocumentDecoderHelper` report at 20:57 and
  `ImageDecoderHelper` reports came during package runs, as they did before this run began.
