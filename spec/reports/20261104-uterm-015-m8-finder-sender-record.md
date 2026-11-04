# UTERM-015 M8: Finder sender record work-queue run

Started 2026-11-04. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-015 M8`, from `spec/proposals/UTERM-015-cross-applet-file-opening.md`. M8 records the sender a Finder open
and a Dock drop report, cold and warm. That record says whether Finder can be told apart from `open -a`. If it cannot,
the decision "Opens that arrive through Launch Services" reopens before M7 builds on it. The specs live in the code
repo, so every commit below is in `/Users/ripta/projects/uniterm`, on the `agent/petunia` branch.

## Run state

The run's base is "Date the M3 amendments and tidy the decision log", which is also the row's base. The row has no
dependencies, and its milestone carries no `Live after` line. Nothing was held or skipped.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-015 M8: Finder sender record | IN PROGRESS | "Read the Finder open sender from the unified log" |

## Local checks

Every milestone runs `make fmt-check`, `make lint`, `make check`, `make test-package`, and `make test-app`, then
`proposals.py check` and `proposals.py freeze`. M8 changes no source code, so the test runs prove only that the tree is
still green.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. Finder is driven through `osascript` with Automation consent over Finder. The Launch Services decision says such a
   program makes Finder the sender, so the event is Finder-sent. If the guess is wrong, the record needs a hand click
   in Finder.
2. The measurement opens a folder, not a file. `Info.plist` declares only `public.folder`, per the Decision Log entry
   for M2's best guesses, item 8. Finder's Open With and the Dock icon would not accept a file, which would fail for
   the wrong reason.
3. A cold launch from Finder has no shell to own its standard error. Its record comes from the unified log, through
   `log stream --level debug`. This amends M8's first check, which says the line is read from a build run directly.
4. Status rule. If the run gets the Finder sender record, cold and warm, M8 is `DONE`, and its As built block names
   the Dock drop and the Release-build Open With as checks left to the user. If nothing is measured, M8 stays
   `IN PROGRESS` and the row stays in the queue. The proposal's M2 review ruling says a check only the user can run
   blocks `DONE`. Splitting M8 again would only recreate it.
5. If Finder cannot be told apart from `open -a`, the run records it for the user's ruling and leaves the decision
   alone. M8's second check says the user rules.

## Milestones

### UTERM-015 M8: Finder sender record

Commit: "Read the Finder open sender from the unified log".

M8 stays `IN PROGRESS`, and its queue row stays, by best guess 4. Nothing was measured.

What the run tried:
- `make build` and `make build CONFIGURATION=Release` both passed, so both bundles exist under
  `.build/DerivedData/Build/Products`.
- The run started `log stream --level debug` for the `dev.uniterm.app` subsystem, and ran the Debug binary directly
  with a scratch layout folder.
- The `osascript` call that drives Finder to open a scratch folder in that bundle was denied by the session's
  permission check. It never reached macOS's Automation prompt. This is the same wall M2 hit.
- A scan of `~/Library/Logs/DiagnosticReports` for new crash reports was denied too. The run stopped the Debug app
  itself, so the scan would have shown nothing about a crash.

Proposal edits, per best guesses 2 and 3:
- M8's first check now reads the sender from `log stream --level debug`, since a cold launch from Finder has no shell.
- M8's last check now says a folder, since `Info.plist` declares only `public.folder`.
- A Decision Log entry dated 2026-11-04 records both, and that the measurement is still owed.

What the user still needs to do is every check in M8. The run wrote a wrapper at
`/private/tmp/claude-501/-Users-ripta-projects-uniterm/d48c7f28-94ae-4284-a1fc-054829ce0e9b/scratchpad/m8/record-senders.sh`.
The scratchpad does not outlive the session, so here is what it does, to rebuild it if needed:
1. Streams `/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "dev.uniterm.app"'` to a file.
   Use `/usr/bin/log`, since zsh has a `log` builtin that shadows it.
2. Walks through eight steps, pausing for Return after each: Finder Open With > Other… and a Dock drop, cold and warm,
   on the Debug bundle and then on the Release bundle. Every step uses a folder.
3. After each step, copies the newest `open-event` line into a summary file next to the script.

The Debug and Release bundles both claim `public.folder`, so Open With may list two uniterm entries. Pick the exact
bundle with Other…, and drag that same bundle to the Dock.

Checks:
- `make fmt-check`, `make lint`, `make check`, and `make test-package` pass.
- `make test-app` failed twice, once under cg and once outside the sandbox. Both runs failed before any test ran:
  "Timed out while enabling automation mode." The run's diff changes only spec text, and the same suite passed on the
  last M3 commit, so the failure is not this work's. The likely cause is the GUI session's automation authorization,
  which may be waiting on a system dialog. It is unresolved, and it does not block.
- `proposals.py check` and `proposals.py freeze` report nothing.

Review:
- The reviewer found nothing. It noted that M2's text at two lines also mentions M8's hand checks. Dismissed: neither
  line says "the file", and M2 is `DONE`.
- `adr-impact` found no conflicts and no ADR candidates. It reads the diff as consistent with ADR-09, since measuring
  a sender grants no authority.

The row review and final review cover the same single commit as this review, so the run did not repeat them. The
milestone review above included the ADR review.
