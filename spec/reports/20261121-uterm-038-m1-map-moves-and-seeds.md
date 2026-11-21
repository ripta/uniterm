# UTERM-038 M1: a program's map move and browser seed act as the user's

Started 2026-11-21. It follows [the UTERM-037 report](20261121-uterm-037-m1-controller-browser-acts-as-user.md). The
user accepted UTERM-038 to build now. They also ruled that a browser pane's layout seed resolves as a typed address
does. The run accepted the proposal and widened it in "Accept UTERM-038 and widen it to the browser's layout seed".
Every commit is in this repo, on `agent/petunia`.

## Run state

The row's base is "Accept UTERM-038 and widen it to the browser's layout seed". It has no dependency and no
`Live after` line.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-038 M1: Program moves and seeds act as the user's | DONE | See "Commits" |

The row is finished. UTERM-038 is `implemented`, and its row moved to `history.md`.

## Commits

1. "Accept UTERM-038 and widen it to the browser's layout seed"
2. "Save a program's map move and run a layout seed as typed", which carries M1, its review fix, UTERM-037's ADR-15
   References line, and this report
3. "Mark UTERM-038 implemented now that map moves and seeds act as the user's"

## UTERM-038 M1

### What was built

- `set-region` saves its region through the path Go to Place uses. MapKit's later report neither saves again nor saves
  a different region, since a set clears the gesture mark.
- A browser pane's layout seed rides to the pane as typed text. At start, the pane runs it through the typed-address
  path, so search text searches and an app address asks. The schemes no source loads, and empty text, are refused at
  parse time, before any pane is made.
- UTERM-008 and UTERM-037 carry "Superseded in part by UTERM-038" markers and Decision Log entries. UTERM-037 also
  gained an ADR-15 References line, from the carve-out citation work.

### Checks

- `make lint`, `make check`: pass.
- `caffeinate -dimsu make test-package`: 2992 tests, 10 skipped, 0 failures.
- `build-for-testing`: pass. `make fuzz` did not run, since no fuzz target covers the layout request.
- `BrowserRemoteUITests`, `BrowserUITests`, and `MapViewerUITests`, run by the coordinator: 24 tests, 0 failures. The
  crash folder holds only the usual `ImageDecoderHelper` reports from package runs.
- `proposals.py check` and `freeze`: only the row-finish findings, and the UTERM-004 References hunk with origin
  `other`.

### Test cost

`MapRemoteTests`: 25 tests in 0.62 s. `LayoutSeedParseTests`, `BrowserWindowTests`, and `BrowserRemoteTests`: 63 tests
in 5.05 s together.

### Best guesses

1. The parse-time check that a search can form a URL runs against every engine, since the engine is read at pane
   start. No engine can fail today, so the check is unreachable and has no test.
2. A seeded pane described before it starts has no first page.
3. A seed whose handoff the user declines leaves the pane blank, as a typed address does.
4. A seed in a detached pane loads at once, as UTERM-037's open does.

### Tests that failed first

The map test failed on the unfixed code. The browser and parse tests were written against the old API, so they failed
to compile rather than on an assertion. The reviewer confirmed that each would fail on the old behavior.

### Review findings

Reviewer: one over-wide line in UTERM-038, fixed. The freeze hunk in UTERM-004 is the earlier ADR-14 References line,
origin `other`. The unreachable search check is noted, not changed. ADR impact: no conflict. ADR-03 and ADR-06 hold,
since a seed is never part of a description and a region adds no field.
