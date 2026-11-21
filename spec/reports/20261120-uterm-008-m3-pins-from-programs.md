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

The row's one dependency, UTERM-004 M3, is met. No milestone carries a `Live after` line. Nothing is held, blocked, or
skipped, and no work is stashed.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-008 M3: Pins from programs | DONE | See "Commits" under M3 |

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
   implementer confirmed by reasoning that macOS shows both controls by default as subviews of the map. The click test
   now rejects any `NSControl` and the MapKit control classes by name. The new test was not run against the unfixed
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
- Left to the user's eye: the "From an earlier run" callout subtitle and status segment, the pin callout, and cluster
  expansion in a live map. The UI test cannot select a pin, since MapKit pins are not accessibility elements.

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
