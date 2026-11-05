# UTERM-008 M1-M2: Map viewer applet work-queue run

Started 2026-11-05. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-008 M1-M2`, from `spec/proposals/UTERM-008-map-viewer-applet.md`. UTERM-008 adds a MapKit map viewer
applet. M1 builds the map pane and its description payload. M2 loads pins from a GeoJSON file. M3, pins from programs,
is a separate row that waits on UTERM-004 M3. The specs live in the code repo, so every commit below is in
`/Users/ripta/projects/uniterm`, on the `agent/petunia` branch.

## Run state

The run's base is "8< --- snip ---", which is also the row's base. The row has no dependencies, and no milestone
carries a `Live after` line. Nothing is held, blocked, or skipped. No commands need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-008 M1: Basic map | DONE | "Add a map viewer applet with standard, satellite, and hybrid styles" |
| UTERM-008 M2: Pins from a file | QUEUED | |

## Local checks

The implementer runs `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package` in the agent
sandbox. It runs `make swiftpm-offline-check` when `Package.swift` changes, and builds the UI tests for testing. M2 adds
`make fuzz`. Then it runs `proposals.py check` and `proposals.py freeze`. The coordinator runs `make test-app` through
cg, since it needs a GUI session and Accessibility permission. The coordinator also checks the crash-report folder for
new uniterm reports.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. The map is two package targets. `GeoData` holds the pin model, GeoJSON extraction, and the label, ID, and accent
   rules, with no AppKit. `MapViewerApplet` holds the AppKit and MapKit applet. This mirrors the data viewer. If the
   guess is wrong, the targets merge.
2. The v1 payload carries every stored field from M1 on: the region, the style, the file layer's default accent, the
   file's path, bookmark, and start directory, and the count of command layers. ADR-06 bumps the version for any
   additive field, and M1's last check asks for this.
3. An unknown stored style decodes to the standard map. It is never treated as damage.
4. The three style commands live in the View menu with no keys, scoped to the pane, per UTERM-013.
5. M2 moves the bookmark resolver and the file-error messages out of the table module into shared code, so the map does
   not depend on the table module. If the guess is wrong, the map duplicates them instead.
6. `marker-color` maps to the nearest accent by OKLab distance against Latte, the one reference flavor.
7. File pin IDs come from the feature's position in the file, and the point's position within a MultiPoint.
8. Clusters stay within a layer by using the layer name as MapKit's clustering identifier.
9. The GeoJSON type identifier is the one this macOS already knows, if any. Otherwise it is a reverse-DNS identifier
   outside Apple's `public.` namespace that conforms to `public.json`.
10. Visual checks are left to the user. The sandbox blocks screenshots of the running app in this run.

## Checks left to the user

- M1: the look of the map in both flavors and all three styles.
- M2: the look of pins and clusters in both flavors.

## M1: Basic map

Commit: "Add a map viewer applet with standard, satellite, and hybrid styles". The proposal edits and this report ride
in the same commit.

### Checks

| Check | Result |
|---|---|
| `make fmt-check`, `make lint`, `make check` | pass |
| `make build`, UI-test `build-for-testing` | pass |
| `make swiftpm-offline-check` | pass |
| `make test-package` | 866 tests, 4 skipped, 21 failures, all in `TerminalSessionIntegrationTests` (see below) |
| `swift test --skip TerminalSessionIntegrationTests` | 847 tests, 4 skipped, 0 failures, after the review fixes |
| `make test-app` | not completed: the app could not come to the front (see below) |
| `proposals.py check`, `proposals.py freeze` | `[]` |
| Crash reports | none new in `~/Library/Logs/DiagnosticReports` |

### Unowned failures

- `TerminalSessionIntegrationTests`: all 21 tests fail with `surfaceCreateFailed` at `GhosttySurfaceView.swift:81`.
  The implementer's first `make test-package` run passed them, and every later run failed. The coordinator's run under
  cg failed the same way. A sandboxed `pty.openpty()` fails with "out of pty devices". The milestone touches no terminal
  code. Unresolved: what holds the ptys. Neither `ps` nor `pgrep` can run in the sandbox, so the coordinator could not
  look.
- `make test-app`, started at 02:28 local time: every test failed at launch with "Failed to activate application
  (current state: Running Background)". The failures started with the first test, `CommandPaletteUITests`, and hit every
  suite until the coordinator stopped the run after 13 failures, about 17 minutes in. A rerun of `MapViewerUITests`
  alone at 02:49 failed the same way in all three tests. The likely cause is a locked or sleeping display, as the
  UTERM-009 report suspected for its late-night runs. That is not proven. Unresolved: whether the map's UI tests pass.
  The run reruns the full UI suite before the row review.

### Best guesses and deviations

- Style commands show titles only. `AppletCommand` has no checked state, and adding one would change the contract. The
  status bar segment names the current style instead.
- The map pane's accessibility value encodes the style and region, so UI tests can read a restored region.
- A region is saved only after a user gesture, which a local event monitor detects. The review found that a one-shot
  echo flag could swallow the first pan and could miss a second MapKit callback. It also found that MapKit's default
  region would dirty an empty pane. A gesture followed by scroll momentum may drop a second settle. That is accepted as
  rare. The monitor itself is unverified in a live window.
- A stored region whose latitude edges pass a pole is corrupt, like any other out-of-range region.
- The file accent is an unvalidated optional string in M1. M2 owns accent semantics.
- A failed map load shows a banner and a status warning, and the map stays usable.
- The launcher entry is "Map viewer", with Cmd-4 inside the launcher.

### Review findings

| Finding | Verdict | Disposition |
|---|---|---|
| Echo flag stuck when `setRegion` changes nothing | PLAUSIBLE, trace confirmed | fixed: gesture gate |
| A second MapKit callback after restore rewrites the layout | PLAUSIBLE, trace confirmed | fixed: gesture gate |
| An empty pane's default region dirties the layout | PLAUSIBLE, confirmed by a test | fixed: gesture gate |
| Region edges past a pole reach `setRegion` | PLAUSIBLE, trace confirmed | fixed: edge check and tests |
| Settle test passes without exercising suppression | PLAUSIBLE, trace confirmed | fixed: tests rewritten to fail without the gate |
| Banner literal past 100 columns, missing separator | CONFIRMED | fixed |
| `describe()` fallback hides an encode failure | CONFIRMED | fixed: `assertionFailure` before the fallback |
| ADR-07 (proposed): MapKit in-process | ADVISORY | As built now states the bound |

`adr-impact` found no conflict and no supersession across ADR-01 to ADR-09. It named two uncovered decisions.
`ThemeFlavor.isDark` as the palette-to-system-appearance rule fails the "hard to reverse" test, since one property is
cheap to change. MapKit's network use is the proposal's settled MapKit decision and an accepted risk, not a new one.
Neither is recorded as an ADR candidate.

### Test cost

| Class | Tests | Wall time |
|---|---|---|
| GeoRegionTests | 4 | 0.001 s |
| MapStyleTests | 2 | 0.000 s |
| MapViewerAppletTests | 12 before the review fixes | 0.234 s |
| MapViewerDescriptionTests | 7 | 0.001 s |
| ThemeFlavorAppearanceTests | 2 | negligible |
| MapViewerUITests | 3 | not run |

## M2: Pins from a file

Queued.
