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
| UTERM-021 M2: Declared files | IN PROGRESS | |
| UTERM-021 M3: Signed files | QUEUED | |
| UTERM-021 M4: Strict and unsafe modes | QUEUED | |
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
