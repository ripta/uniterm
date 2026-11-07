# UTERM-006 M1-M3: Image viewer applet work-queue run

Started 2026-11-07. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-006 M1-M3`, from `spec/proposals/UTERM-006-image-viewer-applet.md`. UTERM-006 adds an image viewer pane.
ImageIO decoding runs in a sandboxed helper process, one per pane. The specs live in the code repo, so every commit
below is in this repo, on the `agent/petunia` branch.

## Run state

The run's base is "8< --- snip ---", which is also the row's base. The row has no dependencies, and no milestone
carries a `Live after` line. Nothing is held, blocked, or skipped, and no work is stashed. No commands need the user's
credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-006 M1: Show one image | DONE | "Add an image viewer that decodes in a sandboxed helper" |
| UTERM-006 M2: Folder slideshow | DONE | "Step through a folder of images as a slideshow" |
| UTERM-006 M3: Zoom | DONE | "Zoom images to actual size and beyond with tiles from the helper" |

## Local checks

The implementer runs `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package` through
`cg_run`. It also runs `make swiftpm-offline-check`, since `Package.swift` changes, and `make fuzz` for the wire codec.
Then it runs `proposals.py check` and `proposals.py freeze`.

The coordinator runs the rest through `cg_run`, outside the agent sandbox. A sandboxed helper cannot start inside the
agent's own sandbox. That covers `make test-app` and the checks against the real signed helper in the built app. After
those runs, the coordinator checks the crash-report folder for new uniterm and xctest reports.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. Sandbox mechanism: the helper takes its sandbox from an entitlements file outside `App/`, and the build setting
   stays off. This is option (a) of M1's sandbox-check bullet. If Xcode will not sign the key that way, the script is
   scoped to the app target instead, and M1 records the switch.
2. A DEBUG-only argv mode in the shipped helper tries to open a file by path and to make a network connection. Both
   must fail. Release builds compile the mode out. If that turns out wrong, a separate probe tool signed with the same
   entitlements proves the profile instead.
3. The type sample is a package test. It skips unless `UNITERM_IMAGE_HELPER` names a built helper. A make target runs
   it against the bundled helper. Samples come from `CGImageDestination` for each writable type. Types with no encoder
   are listed in the As built block.
4. The per-helper cap is 1 GiB. The app-wide image-helper budget is the smaller of 4 GiB and a quarter of RAM. This
   rests on UTERM-003's helper budget.
5. The app-side bitmap budget is the smaller of 1 GiB and a quarter of RAM. Each pane gets a floor sized for a fit
   backdrop. This rests on the data viewer's table budget.
6. The decode time bound is 10 seconds per request. No document sets one.
7. The supported types come from the helper's hello, filtered by conformance to `public.image`. Before the first
   helper answers, the open panel accepts by that conformance.
8. M1 lists a folder and shows its first image. Stepping is M2.
9. The applet menu is titled "Image Viewer", and command IDs are `image-viewer.<name>`.
10. In the launcher, the image viewer comes after the existing viewers.

## UTERM-006 M1: Show one image

### Commits

- "Allow swiftc and the built-app sandbox check in the cg allowlist". The user approved two prompts while M1 ran: the
  implementer's `swiftc` probe, and `check-sandbox-off.sh` run on the built app. Those approvals added the two lines,
  and they are committed on their own.
- "Add an image viewer that decodes in a sandboxed helper". This commit holds the code, the proposal, and this report.

### What was built

- Five package targets:
  - `ImageWire`: the wire codec, fuzzed.
  - `ImageDecoding`: the helper-side ImageIO code.
  - `ImageDecoderHelper`: a SwiftPM executable, for unsandboxed tests.
  - `ImageViewerModel`: pure logic.
  - `ImageViewerApplet`.
- A native Xcode tool target, `Helpers/ImageDecoder`, copied into `Contents/Helpers`. Its entitlements file sits
  outside `App/`.
- `scripts/check-sandbox-off.sh` still guards the app. It now also checks that the helper is sandboxed with
  `<true/>` and holds no file or network key. It also checks that no other target points `CODE_SIGN_ENTITLEMENTS` at a
  file.
- A new `make test-helper-sandbox` target. It is part of `make test`.

### Checks

- The implementer ran these, and all passed:
  - `make fmt-check`, `make lint`, `make check`, and `make build`.
  - `make test-package`.
  - `make swiftpm-offline-check`.
  - `make fuzz FUZZ_ITERATIONS=500`.
  - `build-for-testing`.
  - `proposals.py check`.
- The coordinator ran these outside the agent sandbox:
  - `make test-helper-sandbox` passed, before and after the review fixes. The shipped signed helper was denied a file
    open by path and a network connection. 18 of the 58 types it reports decode under its sandbox.
  - `scripts/check-sandbox-off.sh <built app>` passed, before and after the fixes.
  - `make test-app` passed 114 tests with 0 failures. That includes the 4 new `ImageViewerUITests`.
  - `make test-package` passed after the fixes: 1,634 tests, 5 skipped, 0 failures.
- Crash reports: the only uniterm-related reports are deliberate `abort()` calls from the SwiftPM test helper's fault
  injection. Reports from another session's Rust project landed in the same window. They are not this run's.
- Visual check: the Display P3 screenshot shows a 400 by 200 image at actual size, centred and not enlarged, with
  "400 × 200" in the status bar.
- The comparison against Preview is left to the user. It covers the Display P3 image, the HDR image, and the
  animation.

### Stall

The implementer waited about 23 minutes on a permission prompt for an ad-hoc `swiftc` probe. `swiftc` was not in
`.cg.yaml`'s allowlist. The coordinator nudged it once, and the prompt was answered. The probe itself was dropped.

The hang it was chasing was a bug in the implementer's own code. `FramedSocket.deinit` shut down the shared connection,
so the helper's end closed as soon as the spawn returned.

### Test cost

Each new test class was timed alone with `swift test --filter`:

| Test class | Wall time |
|---|---|
| `HelperClientTests` | 1.27 s |
| `ImageViewerAppletTests` | 1.68 s |
| `HelperSandboxTests` | 0.81 s with the helper, and skipped without it |
| `ImageWireFuzzTests` | 0.03 s |
| `PixelRendererTests` | 0.02 s |
| Every other new class | Under 0.02 s |

The 4 new UI tests took 31 s in total. The launcher-to-open-panel flow took 23 s of that.

### Measurements

These come from the unsandboxed SwiftPM debug helper. The shipped sandboxed helper was not measured.

- Spawn to first reply took about 12 to 27 ms.
- The resting footprint was 3 MiB.
- A 3000 by 2000 decode peaked at 72 MiB.

### Best guesses and deviations

The proposal's Decision Log holds each of these as a "(work-queue best guess)" entry.

- The supported types are filtered to those that conform to `public.image`. This narrowed the Rendering bullet.
- The values in run-level guesses 4 to 6, 9, and 10 are as planned. Each budget also has a 256 MiB per-pane floor.
- `ENABLE_APP_SANDBOX` is left unset on the helper target rather than set to `NO`. The pbxproj then holds only `NO`.
- The implementer tells a hung helper from a slow one with a ping that the helper answers from its reader thread.
- The open panel gained an optional `openPanelContentTypes` through `SourceReplacing`.
- `ResolvedSource` gained a public init.

### Review findings

- F2, CONFIRMED: each helper spawn leaked one Task and its event stream. Fixed. The regression test failed before the
  fix.
- F6, a plan gap: the sandbox check tested that the key was present, not that it was true. It also did not stop the
  app from pointing at the helper's entitlements. Fixed. Three negative cases were tried by hand.
- F1, PLAUSIBLE then confirmed: the whole-image decode path, which gain-map images take, ignored EXIF orientation.
  Fixed. A test compares all eight orientations against the thumbnail path, and it failed before the fix.
- F3, PLAUSIBLE then confirmed: the reader accepted an image body of up to 512 MiB whatever was asked. Fixed. The limit
  now follows the request in flight. Two tests failed before the fix.
- F4, PLAUSIBLE then confirmed in principle: `kill()` could race the reap and signal a reused pid. Fixed with
  `waitid(WNOWAIT)`. The race cannot be reproduced on demand. The test pins the fix, not the bug.
- F5, PLAUSIBLE then partly confirmed: the extra copies of an image were real, and they were removed. The claim that
  they cut the usable cap to a third is not confirmed. The peak stayed at 72 MiB on the fixture, so that diagnosis is
  unresolved.
- F7, PLAUSIBLE: the colour mappings in the app and in the helper could drift apart. `ColorMappingTests` now pins them
  together. It passes, so it is a pin, not a regression test.

### ADR review

`adr-impact` found no conflicts. ADR-07 and ADR-08 are advisory and consistent. It raised three candidates:

1. The app runs outside the App Sandbox, and a helper that needs no file or network access runs inside it. This one
   passes the bar, because it cuts across the system. It is recorded in UTERM-006's Decision Log as `Undecided`.
2. The shared helper process contract. Lifted to its invariant, ADR-07 already holds it: process isolation brings a
   version handshake. The socketpair and the framing are mechanism. It fails the architecture test.
3. The debug-only probes and fault hooks are testing policy, not architecture.

### Found but not made

- `proposals.py freeze` flags four hunks in UTERM-013 with origin `other`. They are another session's edits, left for
  the user.
- The UI test's screenshot captures the whole screen, including the user's other windows. It stays local in the
  `.xcresult`, but it should capture only the window. This is folded into M2's brief.

## UTERM-006 M2: Folder slideshow

### Commit

"Step through a folder of images as a slideshow" holds the code, the proposal, and this report.

### What was built

- Stepping by keys and by registry commands in an "Image Viewer" applet menu with no chords.
- A 5-second slideshow that pauses on detach.
- Name and date order, partial listing, and Reload.
- Skipping deleted files, and the "Folder not listed" segment.
- Restore into folders.
- An idle-slot prefetch.
- The helper now keeps up to four opened sources in an LRU, keyed by the source ID the protocol already carried.
- The UI test screenshots now capture only the window.

### Checks

- The implementer's checks:
  - `make fmt-check`, `make lint`, `make check`, and `make build` passed.
  - `make test-package` passed after the review fixes: 1,688 tests, 5 skipped, 0 failures.
  - `proposals.py check` passed.
- The coordinator's checks:
  - `make test-helper-sandbox` passed against the signed helper with the LRU change.
  - `make test-app` ran twice:
    - On the code before the review fixes: 117 tests, 1 failure.
    - On the fixed code: 1 failure, in a different test. XCTest restarted after that failure and ran the rest
      cleanly.
    - All 7 `ImageViewerUITests` passed both times, including M2's three new tests. See "Unowned failures" below.
  - Crash reports: no new uniterm, xctest, or shipped-helper reports. The `ImageDecoderHelper` reports all come from
    the package tests' deliberate aborts, and all predate the UI runs.

### Unowned failures

Two data viewer UI tests each failed once in a full suite. Each passed 3 of 3 times run alone on the fixed build.
Neither touches image viewer code.

1. `DataViewerUITests.testEditFindExistsAndIsDisabledWithNoFile`
   - It failed in the first run, at `DataViewerUITests.swift:365`.
   - XCUITest raised "Invalid parameter not satisfying: point.x != INFINITY" when it clicked Edit > Find. The menu
     item had no hit point.
   - It passed in M1's full run and in the second full run.
   - Run alone 3 times: run `72S6TD`.
2. `DataViewerUITests.testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile`
   - It failed in the second run, at `DataViewerUITests.swift:60`.
   - The open panel's go-to field autocompleted the typed temporary path. `dev.uniterm.app.UITests.xctrunner` became
     the neighbouring container directory `dev.uniterm.UITests.xctrunner`, which also exists on disk.
   - Run alone 3 times: run `4VFZCV`.

What stays uncertain:
- The first failure appears only in suite order. An earlier test may leave the menu bar in a state XCUITest cannot hit.
  M2 is the first change to add an applet menu, so a link to M2 is not ruled out for it.
- The second failure is a race between the go-to field's autocomplete and the test's typing. It is independent of this
  run. A fix would use a temporary directory whose path no other container's path is a prefix of.

### Best guesses and deviations

The proposal's Decision Log holds each one as a "(work-queue best guess)" entry.

1. Play and Pause is one command, "Play or Pause Slideshow", because a registry command has a fixed title.
2. A partial listing keeps arrival order, and each 256-entry batch is sorted within itself. The full order applies when
   the scan ends. A fresh large folder may first show an image that is not first in Finder order.
3. A step to a cached image, the previous one or the prefetched one, skips the disk check for deletion. A stalled
   mount would otherwise block the step. The deletion is found at the next step that needs the file.
4. The helper keeps four sources in an LRU with no protocol version bump. The helper ships in the same bundle, so no
   skew applies.
5. A bug in M1's client cleared the in-flight decode's expectation on open. It is fixed.
6. When a single file and its bookmark are both gone, restore opens the current image in the old folder.
7. Reload re-lists through the held folder handle.
8. The selection moves at once, and the pane loads one image at a time.
9. Up to three fit bitmaps are charged to the bitmap budget.
10. A failed prefetch is not retried until a reload or a new source.

### Review findings

- F1, CONFIRMED: the scheduler replaced a pending prefetch with a frame request without telling the applet. A later
  step hung. Fixed with a `prefetchDropped` event. The regression test failed before the fix.
- F2, CONFIRMED by trace: a detach during a prefetch's file open stranded the job, and a later step hung. Fixed. The
  regression test, with a gated opener, failed before the fix.
- F3, PLAUSIBLE then confirmed: the full-listing sort ran on the main actor. 100,000 names took 0.66 s in a debug
  build. The sort now runs on the scan thread or off-main. The linear position lookups per step were not measured.
- F4, PLAUSIBLE then confirmed: the client's mirror of the helper's source LRU drifted on reverse travel. A cached
  animated image could then freeze on frame 0. Fixed. The regression test failed when the bug was re-added.
- F5, PLAUSIBLE then not confirmed: a step already saves the layout, through `appletDidChange` and
  `notifyLayoutIfDescriptionChanged`. A pinning test was added.
- F6, proposal: the amendment marker on the deleted-file bullet. Fixed, and the bullet keeps the folder-not-listed
  behavior.

### ADR review

`adr-impact` found no conflicts. ADR-03, ADR-04, and ADR-05 are consistent, and ADR-07 and ADR-08 are advisory. It
raised two candidates, and neither passes the bar.

- The rule that applet commands carry no chord and plain keys are view-local applies UTERM-013 and ADR-04. It is not a
  new invariant.
- One fixed title per registry command is a mechanism of the registry contract. The map viewer already follows it.

### Test cost

Each new or changed class was timed alone with `swift test --filter`, before the review fixes.

| Test class | Wall time |
|---|---|
| `ImageViewerNavigationTests` (25 tests) | 2.4 s |
| `ImageViewerAppletTests` | 1.6 s |
| Every other new or changed class | Under 0.03 s |

M2's three new UI tests took 17 s together.

## UTERM-006 M3: Zoom

### Commit

"Zoom images to actual size and beyond with tiles from the helper" holds the code, the proposal, and this report.

### What was built

- Fit, actual size, and free zoom.
  - Pinch, and Zoom In (Cmd-+), Zoom Out (Cmd--), Actual Size (Cmd-0), and Zoom to Fit (Cmd-9) in the View menu.
  - Actual size honours the declared dpi, so a 144 dpi screenshot shows at half its pixel size.
- Panning by scroll, drag, and arrows. Space still steps, and a step returns to fit.
- Tiles from the helper.
  - The fit backdrop stays on screen.
  - Tiles are 512 px, kept in a cache bounded to one ring around the viewport.
  - Decodes stop at 1:1. Past 1:1 the view magnifies with nearest-neighbour sampling.
- Refusals and limits.
  - A zoom the helper cap or budget refuses posts a warning and goes back to the last zoom that worked.
  - Another pane's helper is never killed.
- Detach releases the tiles and the helper's level decode.
- The helper protocol moved to version 2. The helper now reports the declared dpi, and there are region request and
  region release messages. The handshake still refuses a mismatch.
- Pixel buffers of 256 KiB and up come from mmap, so a freed bitmap leaves the helper's footprint.
- One App Shortcuts remap of "Actual Size" moves the terminal's item and the viewer's item together. A package test
  and a UI test cover this.

### Checks

- The implementer ran these after the review fixes, and all passed:
  - `make fmt-check`, `make lint`, `make check`, and `make build`.
  - `make test-package`: 1,735 tests, 5 skipped, 0 failures.
  - `make fuzz FUZZ_ITERATIONS=500`.
  - `build-for-testing`.
  - `proposals.py check`, apart from the row's move to history.
- The coordinator ran these outside the agent sandbox:
  - `make test-helper-sandbox` and `check-sandbox-off.sh <built app>` passed, before and after the review fixes.
  - `make test-app` on the code before the review fixes ran 120 tests, with 1 failure in M3's own new remap test.
- The remap test's negative check called `waitFor` on a segment that correctly does not exist. That fails on an
  absent element instead of returning false. So the remap worked, and the assertion was the bug. The test now uses
  `waitForExistence`.
- `make test-app` on the final code ran 120 tests with 1 failure, `WindowsUITests.testCommandWClosesOnlyTheKeyWindow`.
  All 10 `ImageViewerUITests` passed.
- Crash reports: nothing from uniterm, xctest, or the shipped `ImageDecoder`. The `ImageDecoderHelper` reports are
  the package tests' deliberate aborts.

### Unowned failure

`WindowsUITests.testCommandWClosesOnlyTheKeyWindow` failed in M3's final full run at `WindowsUITests.swift:120`. The
shell's `K:42:` output never appeared within 20 s.

Run alone 3 times (run `61BE23`), it passed twice. The third run failed at `:116`. The app was
`runningBackground` (state 3), not `runningForeground` (state 4).

Both failures fit another app taking the foreground during the test. The test touches only terminal and window code,
which no milestone in this run changed. It was not run on the base commit, since the run never switches branches. Its
cause is unresolved.
- Left to the user:
  - how smooth pinching and panning feel;
  - whether 1:1 detail matches Preview.

### Best guesses and deviations

The Decision Log holds each of these as a "(work-queue best guess)" entry.

1. Animated images do not zoom, and the zoom commands are off for them.
2. The decode level is the smallest power-of-two fraction of native that is not below the device resolution, capped
   at native. This narrows "the smaller of zoom and native 1:1", so a pinch does not redecode on every step.
3. A refused or failed zoom goes back to the last zoom that showed tiles, or to fit.
4. Values:
   - zoom steps double or halve, and stop on actual size;
   - the largest magnification is 32 device pixels per image pixel;
   - tiles are 512 px with one ring;
   - the horizontal dpi applies to both axes, and an undeclared dpi counts as 72;
   - arrows pan a fifth of the pane.
5. The protocol moved to version 2. The helper ships in the same bundle, and the handshake refuses a mismatch.
6. A step or resize waits behind a tile already in flight, as a known limit. The first tile of a level carries the
   whole level decode, which only a kill can cancel. The 10 s decode bound limits the wait. A 6000 by 4000 PNG level
   took about 0.3 s in a debug build. A step does replace every waiting tile.
7. Additions, tagged `addition`, which the user may drop:
   - double-tap toggles actual size;
   - a zoom-percent status segment.

   Drag to pan is not an addition, since a check covers panning.

### Review findings

- F1, scope: the double-tap toggle and the zoom-percent segment were additions with no tag. They are now logged as
  additions, and the run's best guess keeps them.
- F2, PLAUSIBLE then confirmed: the app and the helper could size a tile level differently by one pixel. That
  happened in 80 of 208 combinations, with ImageIO's thumbnail rounding against the app's. Tile replies were checked
  only against an upper bound. Both sides now use one shared function, and the helper draws at exactly that size. The
  app refuses any tile that is not exactly the rectangle it asked for. Tests cover both.
- F3, PLAUSIBLE then confirmed as a known limit: a step waits behind a tile already in flight. This is recorded as
  best guess 6.
- F4, PLAUSIBLE, fixed defensively: a pinch whose end event never came left tile work off. The pinch now clears when
  the window loses key, when the view moves window, on a new image, and on detach. A test covers it.
- F5: a pan test slept for real. It now yields.

### ADR review

`adr-impact` found no conflicts. ADR-04, ADR-05, ADR-07, and ADR-08 are consistent. It raised three candidates, and
none passes the bar.

- Shared menu titles moving under one remap is already UTERM-013's rule.
- The app-wide bitmap budget belongs to one applet's internals.
- The mmap page buffer is a mechanism.

### Bug found in earlier code

The helper's allocator kept freed large blocks, so a sent bitmap stayed in the helper's footprint. A 64 MiB prefetch
left the helper at 67 MiB. Pixel buffers now come from mmap. Two tests failed before the change.

### Test cost

Each new or changed class was timed alone with `swift test --filter`.

| Test class | Wall time |
|---|---|
| `ImageZoomTests` (14 tests) | 5.85 s |
| `ImageViewerNavigationTests` (28 tests, changed) | 3.2 s |
| `HelperServerTests` | About 0.3 s |
| `ImageViewerViewTests` | 0.13 s |
| Every other new class | Under 0.03 s |

`ImageZoomTests` is the costliest new file. It drives real helper processes through zoom, refusal, and detach.

## Row review

### Commits

- "Keep animations at fit, and stop the slideshow when zooming" holds the review fixes, the proposal edits, and this
  report.
- "Finish the image viewer row" moves the row to `history.md`.

### Findings

A holistic reviewer read the range from "8< --- snip ---" to M3's commit, with `adr-impact` beside it.

- R1, CONFIRMED: pinch, double-tap, drag, and scroll bypassed the animation zoom gate. Only the menu commands checked
  `canZoom`. An animated image could zoom, and tiles cut from frame 0 then covered the playing animation.
  - Fixed. The view gates every gesture and the arrow pan.
  - The applet also refuses tiles for an animated image.
  - The regression test failed before the fix.
- R2, a design call: a playing slideshow kept ticking while the image was zoomed, so it snapped back to fit within
  5 seconds.
  - The run's best guess is that zooming past fit is a manual action, so it stops the slideshow like a manual step.
  - Fixed, with an amendment and a Decision Log entry. The test failed before the fix.
- R3, PLAUSIBLE then confirmed: the client sized a kept tile level as 8-bit pixels. HDR levels are half-float, so
  the cap and budget checks estimated half the real size.
  - Fixed. The client records each source's output space, and an unknown space counts as F16.
  - The test forces the HDR space on a real helper, because no real HDR fixture exists. It failed before the fix.
- R4, PLAUSIBLE then confirmed: the app's mirror of the helper's source order moved before a request could be refused.
  - Fixed. The mirror moves only when a request is sent. The test failed before the fix.
- R5: removed dead code, `tileInFlight`.
- R6: M2's As built block said zoom was not built yet. It now points at M3.
- R7: M3's As built block now says drag-to-pan falls under the panning check. Double-tap is the only gesture no check
  names.
- R8: removed a stray blank line in the Decision Log.
- R9: a crashed, stopped, or misbehaving helper during a zoom said "The zoom limit was reached". Each now says what
  happened. The limit text stays for the cap, the budget, and an overrun.

### Checks

- The implementer's checks:
  - `make fmt-check`, `make lint`, `make check`, and `make build` passed.
  - `make test-package` passed: 1,739 tests, 5 skipped, 0 failures.
  - `build-for-testing` passed.
  - `proposals.py check` and `freeze` passed.
- The coordinator's checks:
  - `make test-helper-sandbox` passed.
  - `make test-app` passed: 120 tests, 0 failures.
  - No new crash reports from uniterm, xctest, or the shipped helper.

### ADR review

`adr-impact` on the whole row found no conflicts and no supersessions. ADR-07 and ADR-08 are advisory.

- The App Sandbox candidate stays as recorded. The row adds one fact: the helper receives files as descriptors over
  its socket, so it needs no file entitlement.
- The per-helper cap and app-wide budget policy was weighed and fails the bar. The values are numeric defaults. The
  invariant behind them already follows UTERM-003 and ADR-07: a pane's helper is never killed to make room.

### For M4

M4's `zoom` command should state what it does for an animated image. Animated images do not zoom in M3.
