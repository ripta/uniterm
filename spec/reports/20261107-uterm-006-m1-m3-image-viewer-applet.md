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
| UTERM-006 M2: Folder slideshow | QUEUED | |
| UTERM-006 M3: Zoom | QUEUED | |

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
