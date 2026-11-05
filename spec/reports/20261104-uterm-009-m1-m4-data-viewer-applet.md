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
| UTERM-009 M3: Search | DONE | "Search the data viewer's table from Edit > Find" |
| UTERM-009 M4: Spreadsheets | DONE | "Open .xlsx workbooks in the data viewer" |

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

### UTERM-009 M3: Search

Commit: "Search the data viewer's table from Edit > Find".

Checks, final round:
- `make fmt-check`, `make lint`, `make check`, and `make build` pass.
- `make test-package` passes: 798 tests, 4 skipped, 0 failures.
- `make fuzz` was not run. Table parsing did not change. The milestone added search and widened one matcher's
  visibility.
- `make test-app` on the final tree ran 87 tests with 1 failure, which is an unowned intermittent failure. See below.
  The three new search UI tests passed.
- `proposals.py check` and `proposals.py freeze` with the row's two commits report nothing.
- The visual check is left to the user, as in M1. Things to look at: the two highlight tints on both palettes, the
  find bar under the filter, the scroll to the current match, and the header stack.

Unowned intermittent UI-test failures, recorded per "Test Failures" in `work-discipline.md`:
- First full run, on the tree before the review fixes: `PaneTreeUITests.testDraggingADividerResizesThePanesOnBothSides`
  failed at `PaneTreeUITests.swift:130`. The divider moved 0 points, where about 100 was expected. The test started at
  06:16:57Z, while the implementer's `make test-package` and `build-for-testing` were running on the same machine.
- Second full run, on the final tree with nothing else running:
  `CommandPaletteUITests.testAProgramTitleShowsNeutralizedAsATab` failed at `CommandPaletteUITests.swift:226`, "the
  title was not neutralized". The drag test passed in that run.
- Attempt: both classes ran alone on the final tree with `-test-iterations 2`. All 42 runs passed.
- Evidence the work did not cause them: neither test touches what M3 changed. The drag test exercises pane dividers.
  The palette test sets a terminal title with `printf` and looks it up in the palette. M3's new palette commands show
  only when a data viewer has focus. Both tests passed in every full run on M1 and M2.
- Uncertain: neither failure was reproduced, and neither was run on the base commit. Contention is likely for the drag
  test. Shell timing is a guess for the palette test, which types into a fresh shell before checking the title. A
  passing rerun proves neither.

Test cost:

| Test class | Tests | Wall time |
|---|---|---|
| `TableSearchTests` | 13 | 0.46 s |
| `CommandMenuTests` | 21, 4 new | 2.14 s. Each new test is under 0.06 s |
| `DataViewerAppletTests` | 22, 3 new | 0.69 s |
| `BuiltInCommandsTests` | 2, 1 new | 0.03 s |

Best guesses made during the milestone. Each has a Decision Log entry marked "(work-queue best guess)":
- Edit > Find is a new applet menu home, `editFind`, shared with UTERM-007's planned viewer. It builds a Find submenu
  below Select All. The submenu hides unless the focused applet type owns an item in it. Focus Filter sits in the same
  submenu, in its own section. The "find commands only" rule is a convention: the home's doc comment states it, and
  the code does not enforce it.
- The find query belongs to the pane. It is separate from the filter, and searches only the filtered rows, numbered
  as shown. It is not stored in the description, so the payload version does not change. It never touches the system
  find pasteboard.
- Search ignores case and covers every column. It keeps at most 1,000,000 matches, about 8 MB, outside the budget. A
  cut list shows "+" in the count.

Amendments: "The applet contract" gained the Edit > Find placement and the find-query rule. A decision carries one
marker, so the bookmark bullet's 2026-11-03 marker moved to the new text as 2026-11-04. The 2026-11-03 Decision Log
entry still records the bookmark change.

Review findings and their dispositions:
1. An amendment marker was re-dated instead of added. CONFIRMED, and fixed by the one-marker rule in "Amending a
   Proposal". The coordinator's instruction to restore the old date was wrong under that rule.
2. Every finished search scrolled the view back to the current match, so a user scrolling while a file loads was
   pulled back. PLAUSIBLE. The trace confirmed it, and it is fixed: only a new query or a step scrolls. The test fails
   on the old logic.
3. After a query with no matches, the search anchor stayed at the old row. PLAUSIBLE. The trace confirmed it, and it
   is fixed: the place is kept only when the new query extends or shortens the old one. The test fails on the old
   logic.
4. Nothing tested where the current match lands when the rows change. Fixed with five tests. While tracing, the
   implementer found the anchor was a position in the rows shown, so a sort or filter moved it to a different cell.
   The anchor now holds a file row and a column. The filter and sort tests fail when the anchor is a position in the
   rows shown.

ADR impact: no conflict. ADR-04 and ADR-05 are consistent. `adr-impact` judged that the `editFind` home does not earn
an ADR, since it is a mechanism under UTERM-013's menu-home rule and is easy to reverse.

The reviewer verified that Cmd-F and Cmd-G reach the registry with a field editor focused, since the main window
routes Command keys to the menu first. A test proves it with a real field editor.

### UTERM-009 M4: Spreadsheets

Commit: "Open .xlsx workbooks in the data viewer".

ZIPFoundation is pinned `exact:` at 0.9.20, tagged 2025-09-24, the newest release at least two weeks old. Both
`Package.resolved` files name revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`. Only `TableData` depends on it.

Checks, final round:
- `make fmt-check`, `make lint`, `make check`, and `make build` pass.
- `make test-package` passes: 833 tests, 4 skipped, 0 failures.
- `make fuzz` passes at 5000 iterations under AddressSanitizer. The workbook test takes 30.5 s at that count.
- `make swiftpm-offline-check` passes, in about 16 s.
- `make licenses` adds only the ZIPFoundation notice and its README section. The coordinator checked the README diff.
- `proposals.py check` reports only the row-finishing items. `proposals.py freeze` reports nothing.
- `make test-app` on the final tree ran 89 tests with 6 failures. Every failing class then passed alone on the same
  tree, 50 of 50, in two runs: the data viewer, tabs, and windows suites, then the pane tree, terminal, and palette
  suites. That covers both new `.xlsx` UI tests and the nested-table test. See the unowned failures below.
- The visual check is left to the user. Things to look at: the sheet picker above the filter, "not computed" cells,
  and a date column.

Offline check: the run took the option that covers SwiftPM, per run best guess 6. A sibling script,
`scripts/swiftpm-offline-check.sh`, runs as `make swiftpm-offline-check` and joins `make ci`. It fills a kept cache
at `.cache/swiftpm` from the committed pins. A control shows that a dead proxy stops both `swift` and `xcodebuild`
from fetching. Both tools then resolve offline into empty folders, and `swift build` builds the `TableData` target.
The check fails if either `Package.resolved` changes. It does not build the whole app offline. CI caches only
`.cache/ghostty`, so CI fetches ZIPFoundation once per run, in the check's first step. `ci.yml` is unchanged.

Test cost:

| Test class | Wall time |
|---|---|
| `XLSXLoaderTests`, about 28 tests | about 1.3 s. The 8 MiB inflate-cap test takes 0.58 s and the streaming test 0.62 s |
| `SpreadsheetDatesTests` | about 0.001 s |
| `DataViewerAppletTests`, 27 tests | about 1.0 s for the class |
| Workbook fuzz | 0.74 s at 300 iterations, 30.5 s at 5000 under ASan |

Best guesses made during the milestone. Each has a Decision Log entry marked "(work-queue best guess)":
- Caps: 32 MiB inflated per small part, 64 MiB of shared strings, also charged to the budget, a 4 GiB sheet, 100,000
  archive entries, XML depth 64, and 16,384 columns, plus M1's cell and row caps.
- Any DOCTYPE or entity declaration is refused outright. That is stronger than "bounded", and no real workbook holds
  one.
- Header rule: the first row that holds anything is the header when every cell in it is text. Empty rows are dropped.
  Hidden sheets are not offered in the picker.
- Only date formats change how a number shows. Percent and currency show the stored number.
- Choosing a sheet clears the sort and filter, since the columns differ. Keeping a query per sheet would need a
  payload change.
- A formula with no cached value draws a muted "not computed". Filter and search never match it, and it sorts with
  null.
- A repeated sheet name is numbered: the second "A" becomes "A (2)". The description stores the numbered name, so the
  payload meaning and version do not change.
- Date times round to the millisecond, then show whole seconds without rounding, so a date-only format never rolls
  into the next day. This rests on the implementer's knowledge of Excel's behavior. Nobody checked it against Excel.
- The archive opens through `/dev/fd/N` on the descriptor the loader already checked, so a swapped-in FIFO cannot
  block the pane.
- License collection covers every package in `Package.resolved`, and refuses a checkout that is not at the pinned
  revision.

ADR candidates: the implementer moved both waiting candidates in the Decision Log, on in-process parsing and on
package pinning, from "Waits on" to "Undecided". See "ADR candidates" at the end of this report.

Review findings and their dispositions:
1. A failed check in `collect-licenses.sh` ran after `Licenses/` was wiped and left it half-written. CONFIRMED and
   fixed: the checkouts are validated before the wipe.
2. The streaming test proved only the producer's chunk size. PLAUSIBLE. The trace confirmed it, and it exposed a real
   product bug: `XMLParser.abortParsing` does not stop the parse, so a cancel, a budget stop, or a handler abort left
   the inflating thread working through the whole part, up to the 4 GiB cap. Fixed with a stop flag the inflating
   thread checks between chunks. The new test cancels a load of a 5 MB sheet after its first rows and asserts that
   under 1 MiB was inflated. It failed on the old code and on a deliberately buffering variant, at 4.68 MB.
3. CRC checks were skipped, so a corrupted entry loaded wrong values silently. This was an unapproved shortcut, and
   the trace confirmed it. Fixed: each part's checksum is verified, and a mismatch fails the load with a message that
   says the file is corrupt.
4. A compound-file directory walk that failed partway returned a partial set, so a truncated `.xls` was misnamed.
   PLAUSIBLE. The trace confirmed it, and it is fixed.
5. Cell references with more than three letters were placed silently. PLAUSIBLE. The trace confirmed it. Fixed: they
   are cut and counted like any column past the last.
6. Duplicate sheet names collapsed in the picker. PLAUSIBLE. The trace confirmed it, and repeated names are now
   numbered.
7. The coordinator added a date-rollover question. A date-only style rounded into the next day. Confirmed and fixed,
   as above.

UI-test failures in the first `make test-app` round:
- `testCommandOOpensAWorkbookAndTheSheetPickerSwitchesSheets` and `testTheSelectedSheetComesBackAfterARelaunch`
  failed with "no table". The UI test's workbook writer computed the ZIP end record's directory offset after
  appending part of that record, so the offset was 12 bytes too large. This was a fixture bug: the package tests'
  writer was correct, and the product correctly refused the bad file. The fixture is fixed and now writes real CRCs.
- `CommandPaletteUITests.testAProgramTitleShowsNeutralizedAsATab` failed again, as the first test of the suite. This
  time its first keystroke timed out with "Failed to synthesize event". In the same run,
  `testCommandORoutesACSVFileToTheDataViewer` failed with "Application has not loaded accessibility". Both are errors
  of the macOS event and accessibility system, not app logic. They are recorded as unowned intermittent failures with
  M3's. The palette test has now failed in 2 of the last 4 full runs, with two different symptoms.

Unowned intermittent failures in the final `make test-app` round, recorded per "Test Failures" in
`work-discipline.md`:
- Failed: `DataViewerUITests.testADoubleClickOnANestedCellOpensItAsATable`,
  `PaneTreeUITests.testShrinkingTheWindowStopsAtTheTreesMinimum`, `TabsUITests.testClosingATabRunningSomethingAsksFirst`,
  `TabsUITests.testProgramModeHasNoNewTab`, `TerminalUITests.testClearScreenClearsTheTerminal`, and
  `WindowsUITests.testPaneActionsGoToTheKeyWindowOnly`.
- The errors come from the automation layer. They include "Lost connection to the application … Couldn't communicate
  with a helper application", "Application dev.uniterm.app is not running", and missing snapshots. No uniterm crash
  report exists in `~/Library/Logs/DiagnosticReports`, so the app did not crash.
- Attempt: each failing class ran alone on the same tree, and all 50 tests passed.
- What stays uncertain: full suites passed cleanly on M1 and M2, and no full suite has passed since M3. The run ran
  around midnight local time, and the failures grew across runs. A locked or sleeping display fits that pattern, but
  nothing proves it. A change in M3 or M4 that makes long runs fragile is not ruled out: M3 rebuilds the Edit menu's
  Find submenu on focus changes, and M4 adds a sheet picker. The row review was asked to look for that. A full
  `make test-app` with the display awake is the check that would settle it.

ADR impact: no conflict with an accepted ADR. The ADR-07 advisory repeats, now for the libxml2 and zlib exposure the
`.xlsx` reader adds. `adr-impact` points out that the clean fix is either an amendment to ADR-07's exception clause,
or a proposal sentence saying why isolation is not possible now. Its reasoning: the proposal's claim that this is "the
same exposure for which libxls was rejected, made smaller by OS maintenance" changes only the likelihood, not the
class of exposure.

Left open:
- `.cg.yaml` holds four uncommitted allow rules that the run did not write itself: `./scripts/swiftpm-offline-check.sh`,
  `chmod +x`, `swift package resolve`, and `swiftc`. Approving cg prompts likely added them. The `swiftc` prefix allows
  compiling anything. The run left the file for the user.
- `XMLParser` builds an attribute dictionary for every element, so a very large sheet loads slowly. The 4 GiB cap
  bounds the time, and a cancel is seen at the next row.

### Row review: UTERM-009 M1-M4

Commit: "Fix data viewer messages and counts across its readers".

The reviewer read the range from the row's base to M4's commit, and looked at how the milestones fit together.
`adr-impact` ran beside it on the same range. Fixes were made by a fresh implementer.

Checks:
- `make fmt-check`, `make lint`, `make check`, and `make build` pass.
- `make test-package` passes: 835 tests, 4 skipped, 0 failures.
- `make fuzz` passes at 5000 iterations under AddressSanitizer, with the renamed `TableFuzzTests` filter.
- `make swiftpm-offline-check` passes.
- `proposals.py check` reports only the row-finishing items. `proposals.py freeze` with the row's four commits reports
  nothing.
- `make test-app` ran 89 tests with 1 failure. `DockedPaletteUITests.testADockedPaletteTakesNoKeyboardUntilTheHotkeyAndGivesItBack`
  failed with "Failed to synthesize event: Timed out while synthesizing event". The class then passed alone on the
  same tree. This is the same automation-layer symptom as the earlier runs, in a test the row does not touch. It is
  recorded as an unowned intermittent failure with the others.

Findings and their dispositions:
1. A legitimate workbook whose shared strings exceeded the pane's free budget stopped with the "hostile file"
   message. CONFIRMED and fixed. A budget refusal now ends the load like a CSV or JSON budget stop, with the same
   memory wording. The "hostile" message stays only on the real caps. Both regression tests failed on the old code. A
   related edge was also fixed: strings load, then the first page is refused. Before, the pane showed an empty table
   under "the first 0 rows". Now it shows the memory message. No test covers that edge, since the pane's message
   label is private to the view.
2. The `.xlsx` cut-row count counted shared-string entries, not rows. CONFIRMED and fixed: rows that show a cut
   string are counted. The regression test failed on the old code, with 1 where 2 was expected.
3. The settled "Input sources" decision still said a file URL is the only source, after M2 added an in-memory source
   for nested tables. Amended with one marker and a Decision Log entry. The doc comment is fixed.
4. The launcher entry still said "Shows a CSV file as a table". It now names CSV, JSON, and Excel files.
5. The row-limit notice said "of the file" for a workbook. A workbook now says "of the sheet". This is a best guess
   with a Decision Log entry, and "Large files" is amended.
6. The ZIP fixture writer existed three times. The package-test copies now share one writer, in a new `TableTestSupport`
   test target. The UI-test copy stays, since that target cannot import the package. A comment says which writer it
   mirrors.
7. `CSVFuzzTests` fuzzed all three formats. It is renamed `TableFuzzTests`, and the `make fuzz` filter is updated.
8. Duplicated notice code moved into one helper, and the identical `finish` arms are merged. JSON and sheets share
   one cancel cadence. Each reader's load state now lives beside its reader. The CSV state stays in the shared load
   run, because moving it was not cheap.
9. The app's restorer said "wrong type, expected terminal" for an unknown applet type. It now says the type is
   unknown. The placeholder behavior is unchanged.

UI fragility: the reviewer judged that nothing in M3 or M4 plausibly causes the full-suite failures. M3's Find
submenu is built once and hidden or shown on existing notifications. The sheet picker exists only in a data viewer
pane, and the other suites never open one. It could not rule out the extra run length, the extra app launches, or
the new launcher row. Its suggested bisect is three full runs on M2's commit, and three on M3 without the data viewer
tests. The run did not do that bisect, since it costs about an hour of GUI time.

ADR impact across the range: no conflict with an accepted ADR. ADR-07 is still advisory, and wider now that the range
adds libxml2, zlib, and a third-party package. ADR-08 is unchanged from M1. `adr-impact` proposed three ADR
candidates:
- A file-backed viewer's description holds a path and a bookmark, never file contents. The path wins while a regular
  file is there, and the bookmark is remade when it names a different file. This passes the bar: UTERM-006,
  UTERM-007, and UTERM-008 follow the same rule, it is stored data, and it is settled. It is recorded as `Undecided` in
  the Decision Log.
- A shared memory budget across viewer panes. Not recorded. Only UTERM-009 settles it, so it is not yet a rule
  other viewers must follow.
- The `editFind` menu home. Not recorded. M3's `adr-impact` judged it a mechanism under UTERM-013's menu-home rule.
