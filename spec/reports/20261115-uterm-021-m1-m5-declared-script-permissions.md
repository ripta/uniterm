# UTERM-021 M1-M5: declared script permissions work-queue run

Started 2026-11-15. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-021 M1-M5`, from `spec/proposals/UTERM-021-declared-script-permissions.md`. UTERM-021 lets a single Janet
file declare its powers in a first `(declare-permissions ...)` form. The app snapshots the file, reviews the declared
powers, and remembers trust by version or signed identity. Strict mode refuses a file that declares nothing, and a lint
compares a file's calls with its declaration. The specs live in the code repo, so every commit below is in this repo,
on the `agent/petunia` branch.

## Run state

Step 0 fetched `upstream/main`. The branch already held it, so no rebase ran. The run's base and the row's base are
both the commit "Merge pull request #55 from ripta/agent/petunia-1115/bug-filings".

The row has no dependencies and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no
work is stashed.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-021 M1: Run wording | DONE | "Name every one-run choice Allow for This Run" |
| UTERM-021 M2: Declared files | DONE | "Run a script file's declared powers from a reviewed snapshot" |
| UTERM-021 M3: Signed files | DONE | "Trust a signed script file by its key and ID" |
| UTERM-021 M4: Strict and unsafe modes | IN PROGRESS | |
| UTERM-021 M5: The lint | QUEUED | |

## Commands that leave the sandbox

These run with the sandbox disabled, through the permission prompt:

- `git fetch upstream` needs the user's SSH key.
- `make build` and `make test-helper-sandbox` in every milestone.
- `make test-app` and the filtered UI runs, which the coordinator runs.
- Any M3 test that needs the login Keychain for a signing key.

## Local checks

The implementer runs these through `cg_run`: `make fmt-check`, `make lint`, `make check`, `make build`,
`caffeinate -dimsu make test-package`, `make test-helper-sandbox`, `proposals.py check`, and `proposals.py freeze`. It
adds `scripts/swiftpm-offline-check.sh` when `Package.swift` changes, and a scoped `make fuzz` when the wire, the
declaration reader, or a policy reader changes.

The coordinator runs the UI tests through `cg_run`. It runs a filtered `-only-testing:` run of the touched classes,
with a one-class probe first, and one full `make test-app` before the final review. After each UI run it checks the
crash-report folder.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. A plain script is told apart from a generic peer by authenticating the `.begun` peer as the bundled command. The
   proposal's strict-mode decision says the app tells the two apart this way. M1 needs it before M4's undeclared begin
   exists. If the guess is wrong, plain-script questions would need another signal.
2. A scoped kind's duplicate key follows `controller.json`'s existing rule. For `host-launch`, that is the executable
   alone. The proposal says declarations use `controller.json`'s vocabulary and its rules. If the user wants one launch
   per executable and folder, both readers change together.
3. The file policy file is `files.json` in the controllers folder, with `files.aside-<N>.json` and `files.json.tmp-*`.
   This follows "Trust records for files" and the M2 naming check.
4. The file signature's domain line is `"uniterm script file 1\n"`. This follows "Signing" and the M3 check that the
   domains differ.
5. The bound on a declaration's arrival reuses the listener's 5-second begin deadline.
6. ScriptWire goes to version 10 in M2. M4's undeclared begin bumps it again to 11, since each milestone ships alone.
7. Between M2 and M4, an undeclared file keeps today's plain begin, so M2 ships alone. M4 replaces it.
8. Tests that need undeclared behavior, such as the `ffi` and `jit` fixtures, run with the mode set to unsafe. Their
   files stay undeclared.
9. The lint's shared call-to-power table lives in `ScriptWire`, which the Janet isolation check allows.

## UTERM-021 M1: Run wording

Commits: "File the bug where the helper sandbox tests fail after a UI test build", then "Name every one-run choice
Allow for This Run".

The review button, its help text, the waiting-runs text, and the controller approval line now say "run". Each
connection now carries an explicit kind: a controller run, the bundled command running a plain script, a generic peer,
or a REPL pane. A plain begin is checked against the bundled command's code identity. A plain script's questions then
say "Allow for This Run". REPL and generic-peer questions keep "Allow for This Connection".

### Checks

- `make fmt-check`, `make lint`, and `make check` pass.
- `make build` passes.
- `caffeinate -dimsu make test-package` passes: 2455 tests, 9 skipped, 0 failures, 237 s wall.
- `make test-helper-sandbox` passes, 8 tests, after a `make clean`. See the bug below.
- `proposals.py check` and `freeze` report nothing.
- The coordinator ran `ControllerConsentUITests` twice through `cg_run`, before and after the review fixes. Both runs
  passed, 5 of 5. No crash report appeared during either run. The coordinator viewed the review, help, and
  plain-script question screenshots. Each shows "Allow for This Run".

### Best guesses

- The peer check reads the command's file once and keeps the result. Each begin then reads only the running process's
  dynamic signing information on the main actor. The kind is settled before the connection's first call, with no
  per-connection hold. A command replaced on disk after the first read is taken for a generic peer, which changes
  only the wording. If that is wrong, the fix is a per-connection hold while a full check runs off the main actor.
- With no controller settings, every plain begin is a generic peer. The shipped app always has them.

### Review

- A doc comment bound to the wrong function after an insertion. Fixed.
- A comment named a proposal ID. Fixed.
- The As built label was not on its own line, so `proposals.py check` missed it. Fixed.
- The peer check ran a full static signature validation on the main actor for every begin. The trace confirmed it.
  Fixed with the cached file check above. Native-launch pids skip the check.
- `adr-impact` found no conflicts and no ADR candidates. ADR-09 is consistent, since the kind selects wording only and
  grants nothing.

### Bugs found

- `make test-helper-sandbox` failed 4 of 8 tests after a UI test build in the same DerivedData. The test build left
  Xcode's injected entitlements on the helpers. Filed as
  [20261115-helper-sandbox-tests-fail-after-ui-test-build](../bugs/20261115-helper-sandbox-tests-fail-after-ui-test-build.md).
  Its fix needs a design call. Until then, the run does a `make clean` before each `make test-helper-sandbox`.

### Test cost

The package suite took 218 s before the review fixes and 237 s after. The three new wording tests take under 0.2 s
each. `ControllerConsentUITests` takes about 130 s, including its build.

## UTERM-021 M2: Declared files

Commits: "Record the stale clipboard answer test as a potential flake", then "Run a script file's declared powers
from a reviewed snapshot".

A file whose first form is `(declare-permissions ...)` now runs from an app-made snapshot after a review or a
remembered version approval. The command parses the declaration with Janet's own parser in a VM that evaluates
nothing, and reports it as JSON. The app reads it again with the strict reader packages use. ScriptWire is at version
10. File approvals live in their own `files.json`. One table of command processes refuses a second begin or attach
from the same process. The proposal's As built block has the details.

### Checks

- `make fmt-check`, `make lint`, and `make check` pass.
- `make build` passes.
- `caffeinate -dimsu make test-package` passes, 206 s wall after the review fixes.
- Scoped `make fuzz` under ASan, 5000 iterations: `ScriptWireFuzzTests`, `ControllerFormatFuzzTests`,
  `ControllerPolicyFuzzTests`, and the new `DeclaredScriptFuzzTests`. All pass.
- `make clean`, then `make test-helper-sandbox`, passes.
- `proposals.py check` and `freeze` report nothing.
- The coordinator ran `ControllerConsentUITests` before and after the review fixes. Both runs passed, 6 of 6,
  including the new declared-file test. The coordinator viewed the declared file's review and its row in Controllers &
  Permissions. No crash report appeared during either run.

### Best guesses

- An undeclared first form keeps today's plain begin. A near-miss first form is refused. A later declaration is a
  parenthesized form headed by the symbol, outside quote and quasiquote. Mentions in data, quotes, and docstrings are
  not declarations. If a declaration inside quoted data should also refuse, the reader widens.
- A file that does not parse reads as undeclared, so the run reports Janet's own parse error.
- A struct with no `:kind` holding a key within two edits of `kind` is reported as a likely typo. Only the command's
  reader judges this. The app only words the message.
- The snapshot's size cap is a packaged file's, 32 MiB. The declaration wait reuses the listener's 5-second deadline.
- The process table holds 1024 entries. When full, it drops exited processes, then refuses a new begin. Controller and
  file begins claim a slot only after the cheap check says the peer is the bundled command.
- The app refuses any path under `/dev`. It does not require a canonical path, so a link in a middle component still
  passes. `O_NOFOLLOW` guards only the last component, and the command already sent a `realpath`.
- A long file name keeps its start and its extension, with an ellipsis between.
- The host-launch duplicate rule is the plan's best guess 2. The proposal text is amended in place, with a Decision Log
  entry marked as a run best guess.
- The Makefile's `fuzz` target gained the new `DeclaredScriptFuzzTests` filter.

### Review

- An As built line was 212 columns, and it named four parser flag bits where the code mirrors three. Fixed.
- The table test proved only pruning. Tests now cover a table full of live processes and an exact count after pruning.
  Fixed.
- A protocol test repeated the snapshot test's five-case table. It is now one case proving the wire refusal and the
  empty run folder. Fixed.
- A public snapshot API carried a test-only hook. It moved to an internal function. Fixed.
- The misspelled-kind heuristic existed in C and in Swift. Only the C reader judges it now. Fixed.
- The coordinator saw the review cut a file name mid-extension, `...declared-file.ja`. Fixed with the elided name.
- A declaration's name in a parameter list, a quote, a quasiquote, a docstring, or a bracketed list refused an
  undeclared file. The trace confirmed it. Fixed.
- `/dev/fd/N` would make the app open its own descriptor. The trace confirmed it. Fixed with the `/dev` refusal.
- Controller and file begins claimed a table slot before authentication, so a generic peer could fill the table. The
  trace confirmed it. Fixed.
- The Decision Log tag "(run best guess)": dismissed. `/work-queue` says to mark a run's amendment as a run best
  guess.
- `adr-impact` found no conflicts with ADR-07, ADR-09, or ADR-10, and `check-janet-isolation.sh` passes. It raised a
  separate trust store per artifact kind as a possible ADR. It does not pass the bar. A separate file is a mechanism.
  The invariant behind it, that an approval for one artifact kind never authorizes another, sits within ADR-09's rule
  that an approval is a policy for a verified version or identity. It also raised one session per command process,
  which the proposal's Decision Log already declined as an ADR.

### Bugs found

- `uniterm run` on a FIFO or `/dev/fd/N`, such as `uniterm run <(...)`, fails with "cannot read ... you don't have
  permission to view it". The coordinator reproduced it outside the sandbox with the built command. The command's
  `Data(contentsOf:)` read is unchanged since before this run. M4 must keep `uniterm run <(...)` working in unsafe
  mode, so the M4 implementer fixes it as its own commit, with the regression test first.

### Unowned failures

- `TerminalSessionIntegrationTests.testAPendingClipboardAnswerIsStaleAfterAPolicyChangeOrAClose` failed once in a full
  package run. The system pasteboard held text another session had written, where the test expected `SECRET-STALE`. It
  passed alone and in the next full run. It was not reproduced on the base commit. It is listed as a potential flake
  in `spec/flaky-tests.md`.

### Test cost

The package suite took 199 s before the review fixes and 206 s after. `DeclaredFileRunTests` spawns the real command,
14 tests in about 2.1 s. `DeclaredFileProtocolTests` takes about 0.8 s, with the declaration-bound test the slowest at
0.3 s. The other new test files each take under 0.2 s. The new fuzz test runs 400 iterations in the package suite.

## UTERM-021 M3: Signed files

Commits: "Record a second local sighting of the find test's main-actor flake", then "Trust a signed script file by
its key and ID".

`uniterm controller sign --key NAME file.janet` writes `file.janet.sig`. The signature uses its own domain line, so a
package signature never verifies a file and a file signature never verifies a package. The app verifies the `.sig`
over the copied bytes while it snapshots. A signed file offers Trust This Identity. A later version that asks for
nothing new then runs without review.

### Checks

- `make fmt-check`, `make lint`, and `make check` pass.
- `make build` passes.
- `caffeinate -dimsu make test-package` passes: 2551 tests, 9 skipped, 0 failures, 218.5 s wall after the review
  fixes.
- Scoped `make fuzz` under ASan for `ControllerFormatFuzzTests` and `DeclaredScriptFuzzTests` passes.
- `make clean`, then `make test-helper-sandbox`, passes after the review fixes.
- `proposals.py check` and `freeze` report nothing.
- The coordinator ran `ControllerConsentUITests`, 7 of 7 passing, including the new signed-file test. The coordinator
  viewed the signed file's review, which shows "Signed by key" and offers Trust This Identity. The review fixes changed
  error wrapping and tests only, so the UI run was not repeated.

### Best guesses

- The file domain line is `uniterm script file 1\n`, the plan's best guess 4. The proposal's Signing decision is
  amended in place to name both lines.
- `sign` treats a folder as a package and any other path as a file, so the CLI needs no new flag. A missing path
  reports that the file does not exist.
- `sign` writes the `.sig` beside the resolved file, since the app reads beside the resolved path. It prints the path
  it wrote.
- A signed file with no `:id` is refused once its declaration arrives, since the header is known only then. The
  signature itself is checked earlier, at the snapshot. Nothing is shown or kept before the refusal.

### Review

- A `.sig` that was a link or too large failed with a generic contents or I/O error, not the file-signature error the
  As built names. Fixed. Every `.sig` failure now raises the file-signature error.
- The re-sign test asserted only that the bytes changed. It now checks that each signature verifies its own bytes and
  rejects the other's. Fixed.
- The identity-widening test covered a new capability, not a host launch. Dismissed: `ControllerPolicyTests` already
  proves a host launch with another directory, a sibling folder, an extra environment key, or another executable is
  not covered. File and package approvals share that check.
- `sign` routing every non-folder path to the file signer: kept as the best guess above.
- `adr-impact` found no conflicts and no ADR candidates. ADR-09's rule that identity proves continuity, not every
  future power, holds, since a version asking for more is reviewed.

### Unowned failures

- `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread` failed once in a full package run, counting 35
  main-actor turns where it expects more than 100. It passed alone and in the next full run. It was not reproduced on
  the base commit. Its existing potential-flake entry in `spec/flaky-tests.md` now records this sighting.

### Test cost

The package suite took 218.5 s wall, against 206 s after M2. The new signing tests are unit and in-process command
tests, each well under a second. `ControllerConsentUITests` now has 7 tests and took about 250 s including its build.
