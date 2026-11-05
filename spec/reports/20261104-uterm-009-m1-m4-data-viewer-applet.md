# UTERM-009 M1-M4: Data viewer applet work-queue run

Started 2026-11-04. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-009 M1-M4`, from `spec/proposals/UTERM-009-data-viewer-applet.md`. UTERM-009 adds a table viewer applet
for CSV, JSON, and `.xlsx` files, with sorting, filtering, and search. The specs live in the code repo, so every commit
below is in `/Users/ripta/projects/uniterm`, on the `agent/petunia` branch.

## Run state

The run's base is "8< --- snip ---", which is also the row's base. The row has no dependencies, and no milestone
carries a `Live after` line. Nothing was held or skipped.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-009 M1: CSV table | DONE | "Add a data viewer applet that opens CSV files as tables" |
| UTERM-009 M2: JSON | DONE | "Open JSON and JSON Lines files in the data viewer" |
| UTERM-009 M3: Search | QUEUED | |
| UTERM-009 M4: Spreadsheets | QUEUED | |

## Local checks

Every milestone runs `make fmt-check`, `make lint`, `make check`, `make test-package`, and `make test-app`. From M1 on,
it also runs `make fuzz`, which is a local check and not part of `make ci`. Then it runs `proposals.py check` and
`proposals.py freeze`. `make test-app` needs a GUI session and Accessibility permission, so it runs outside the agent
sandbox. Each UI milestone also gets a screenshot of the running app and a crash-report check.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. The viewer is two package targets. `TableData` holds the readers, the row store, the budget, and sort, filter, and
   search, with no AppKit. `DataViewerApplet` holds the AppKit applet. If the guess is wrong, the targets merge.
2. The shared memory budget is the smaller of 1 GiB and a quarter of physical memory. Each pane gets a 32 MiB floor.
   The proposal names no number. If the guess is wrong, only constants change.
3. The CSV rule works in three steps:
   - Encoding: a BOM wins, then valid UTF-8, then Windows-1252.
   - Delimiter: `.tsv` means tab. Otherwise the first 64 KiB is sniffed among comma, semicolon, tab, and pipe, and the
     most consistent field count above one wins. A tie goes to comma.
   - Header: the first row is the header unless one of its cells parses as a number. A headerless column, or an empty
     header cell, is named by position.
4. The fuzzer is a seeded mutator in the repo, run under AddressSanitizer, not libFuzzer. Xcode's toolchain does not
   reliably ship libFuzzer's runtime.
5. M3 adds an Edit-menu home to the applet command contract, for Edit > Find. UTERM-009 and UTERM-007 both place Find
   there, and UTERM-013 fixes only the standard edit actions. If the guess is wrong, Find moves to the applet's own
   menu.
6. M4 extends the offline-build check to SwiftPM fetches, the complete option of the two that M4 allows.
7. Reopen goes through Cmd-Shift-T, since UTERM-013 M2 has landed.
8. Nested tables open in a sheet or popover in the same pane, not as a new pane.
9. In-process parsing does not conflict with ADR-07, which is `proposed`. UTERM-009's untrusted-file risk states why
   isolation is not used and what bounds the exposure. Any ADR-07 finding is recorded as advisory.
10. `make fuzz` stays out of `make ci`. `make test-package` runs the fuzz target at a small count without ASan.
11. In M1, a declared type the viewer cannot read yet, such as JSON before M2, shows a "format not supported yet"
    message.

## Milestones

### UTERM-009 M1: CSV table

Commit: "Add a data viewer applet that opens CSV files as tables".

Checks, final round:
- `make fmt-check`, `make lint`, `make check`, and `make build` pass.
- `make test-package` passes: 744 tests, 4 skipped, 0 failures.
- `make fuzz` passes: 5000 iterations under AddressSanitizer at the default seed, in 188 s. An ASan build links
  against the prebuilt GhosttyKit, so it builds the whole package and filters to the fuzzer.
- `make test-app` passes: 83 tests, 0 failures, in about 11 minutes. The coordinator ran it.
- `proposals.py check` and `proposals.py freeze` report nothing.
- The visual check was not run. The permission check denied the coordinator's script, which launches the app and
  takes a screenshot. It is left to the user, and M1's As built block says so.

Test cost: the new package test classes take about 5 s together.

| Test class | Wall time |
|---|---|
| `CSVFuzzTests`, at 300 iterations | about 2.5 s |
| `TableSessionTests` | 1.0 s |
| `TableLoaderTests` | 0.6 s |
| `DataViewerAppletTests` | 0.46 s |
| `CSVParserTests`, `CSVRuleTests`, `TableQueryTests`, `TableBudgetTests`, `SourceResolverTests`, `TextTranscoderTests`, `DataViewerDescriptionTests` | under 0.2 s each |
| `DataViewerUITests`, 4 tests | about 55 s |

Best guesses made during the milestone. Each has a Decision Log entry marked "(work-queue best guess)":
- Size caps on hostile input: a cell keeps 1 MiB, and a row keeps 16 MiB and 65,536 cells. A cut row is counted, and
  the pane says so. If the guess is wrong, only constants change.
- The file extension picks the reader. CSV, TSV, and TAB load. JSON, JSON Lines, GeoJSON, and spreadsheets say "not
  supported yet". Other extensions are named and refused. A TSV file opens only through the pane's Open or a drop,
  since the router declares CSV and JSON only.
- A header click cycles through ascending, descending, and no sort. Numbers sort before text, text sorts
  case-insensitively, and empty cells come last in both directions. M2 settles the full mixed-type order.
- A bookmark is kept only while it still names the file that opened.
- A sort reserves its key memory from the shared budget. When the budget refuses, the rows stay in file order and the
  pane says so. This came from review finding 2.
- The fuzzer is a class in `TableDataTests`, not its own target, so it shares the test helpers.

Deviation, recorded by amendment: "Large files" said one budget covers every pane, with no floor. M1's bullet says a
pane that opens last still loads rows. The decision now says the app holds at most the budget plus one 32 MiB floor
for each pane beyond it.

Review findings and their dispositions:
1. A released budget lease still granted reservations, so a cancelled loader could re-reserve. CONFIRMED and fixed.
   A released lease now refuses. The regression tests failed before the fix.
2. Budget cost counted elements, not allocated capacity, and sort keys were unreserved. PLAUSIBLE. The trace
   confirmed both parts, and both are fixed. Sealed pages copy into exact-size arrays, and sorts reserve key memory.
   The page being filled stays unreserved, at under about 1 MiB per loading pane. That is documented.
3. The CSV rule sniffed 256 KiB where its docs say 64 KiB. CONFIRMED and fixed in the code, so it matches the
   documented rule. The regression test failed before the fix.
4. Nothing tested the text decoder's carry across read chunks. A new test splits UTF-8, UTF-16 LE, and UTF-16 BE at
   every offset. It passed on the old code, so the carry was already correct, and the test pins it.
5. A focused filter field might keep stale text after a source swap. PLAUSIBLE, and not confirmed. The new test
   passes on the old code. Every replace goes through the "Opening..." message, which ends the field's edit. The
   diagnosis stays unresolved. The test is kept as a pin.
6. A missing file with an unsupported extension said "does not read that format". CONFIRMED and fixed: the loader
   opens and checks the file first. The regression test failed before the fix.

ADR impact:
- ADR-07, Failure Isolation, is `proposed`, so this is ADVISORY. `adr-impact` read its exception clause as asking
  why isolation is impossible. The proposal's untrusted-file risk gives a cost reason and a revisit hook instead. Run
  best guess 9 records this as advisory. The user should settle it before ADR-07 is accepted.
- ADR-08, UI Responsiveness, is `proposed`, so this is ADVISORY. `currentDirectory` checks whether the file's folder
  exists on the main thread. The terminal does the same. No change was made.

UI-test failures in the first `make test-app` round:
- `testARestoredViewerShowsTheFileWithItsSortAndFilterAndStoresNoRows` failed on "the path was not saved". This was a
  test bug: the layout encoder writes `/` as `\/`. The test now normalizes that, and its assertion is unchanged.
- `testCommandORoutesACSVFileToTheDataViewer` failed because the open panel's sheet never closed after the path was
  typed into the go-to-folder field. Typing took 12.7 s in that run, against about 2.7 s in passing runs. The
  implementer added a check that the field holds the exact path before Return. The second round passed. A passing
  rerun does not prove a fix, so the cause stays unresolved. If it recurs, the new check says whether typing mangled
  the path.

Left open:
- The visual check, above.
- The File menu shows two items titled "Open..." when a data viewer has focus. One is the window's routed Open and
  one is the pane-local Open from UTERM-015. The visual check should judge it.
- No UI test drives a drop of several files, since XCUITest cannot start a drag from Finder. Package tests cover it
  on the applet's drop entry point.

### UTERM-009 M2: JSON

Commit: "Open JSON and JSON Lines files in the data viewer".

Checks, final round:
- `make fmt-check`, `make lint`, `make check`, and `make build` pass.
- `make test-package` passes: 777 tests, 4 skipped, 0 failures.
- `make fuzz` passes: 5000 iterations under AddressSanitizer, in 239 s. JSON mutation took 20.7 s and JSON chunking
  28.3 s.
- `make test-app` passes: 84 tests, 0 failures, including the new nested-table test. The coordinator ran it twice:
  once before the review fixes, and once on the final tree.
- `proposals.py check` and `proposals.py freeze --row-commit` on M1's commit report nothing.
- The visual check is left to the user, as in M1.

Test cost:

| Test class | Wall time |
|---|---|
| `JSONLoaderTests` | about 1.1 s, plus the new flood tests, each under a 5 s deadline. A 1.7 MB streaming test takes 0.9 s and proves the load stops after the first chunk |
| `JSONScannerTests` | 0.003 s |
| JSON methods in `CSVFuzzTests`, at 300 iterations | about 0.2 s |
| `DataViewerAppletTests` | 0.67 s for the class |

The fuzz class's ASan run grew from 188 s to 239 s with the JSON corpus.

Best guesses made during the milestone. Each has a Decision Log entry marked "(work-queue best guess)", and the
"JSON shapes" decision is amended for the first four:
- A nested object with more than 64 members is a map, shown as one expandable cell.
- Objects flatten to six key segments. A table holds at most 1,000 columns. Keys past that fold into one `(more keys)`
  cell, so no value is lost.
- Duplicate keys keep every value. The nth repeat of a path in a row fills that path's nth-occurrence column.
- JSON Lines: a `.jsonl` or `.ndjson` name decides. Otherwise a file is JSON Lines when its first 64 KiB holds a
  whole first value and the start of a second.
- Sort order: numbers, text, booleans, nested cells, null, then missing. Null and missing stay last in both directions.
- A syntax error after good rows fails the whole load.
- GeoJSON opens as JSON when it reaches the viewer through its own Open or a drop. The router still sends it to the
  map. M1's As built note is amended to match.
- A nested table opens in a popover with its own session and budget lease.
- A value past the 1 MiB cell cap, or a number past 64 KiB, shows "(value too large to show)" and counts as cut.

Review findings and their dispositions:
1. A hostile wide or duplicate-key element ran up unbudgeted memory and quadratic CPU, and a cancel could not
   interrupt it. CONFIRMED and fixed. Repeats are O(1). A row keeps at most 65,536 cells. The load checks for a
   cancel every 256 rows. The duplicate-flood test took 36.9 s on the old code against a 5 s deadline, and the
   wide-element test failed there too.
2. The plan's visual check was not done. The screenshot was denied in M1, so the check is left to the user, and the
   As built block says so.
3. Positional cells past the column cap folded into `(more keys)` under an empty title. CONFIRMED and fixed: they are
   titled `Column N`. The test failed on the old code.
4. A number longer than 64 KiB failed the whole load. PLAUSIBLE. The trace confirmed it, and it is fixed: the number
   shows the too-large note and counts as cut. Its text is never truncated, because a cut number reads as a different
   value.
5. A scalar-only JSON Lines file named `.json` was misread as one value. PLAUSIBLE. The trace confirmed it, and it
   is fixed. The test failed on the old code.
6. A GeoJSON FeatureCollection opens as key and value rows, and a large `features` member shows the too-large note.
   Recorded in As built as a known limit.
7. The column registry's memory is not charged to the budget. It is bounded at about 50 MiB for a hostile file, and
   kilobytes for real files. Each open popover takes one more 32 MiB floor. Recorded in As built.

ADR impact: no conflict with an accepted ADR. The ADR-07 advisory from M1 repeats for the JSON reader, and ADR-08 is
consistent.

Left open:
- The visual check. M2's As built block lists what to look at: the nested-cell marker and its color, the popover's
  size and position, the muted `null`, and the `(more keys)` column.
- An array of empty objects, such as `[{}, {}]`, has rows and no columns. The pane says "has no rows".
- The cut-rows notice says "rows had oversized cells cut". For JSON it also counts values that were replaced by the
  too-large note.
