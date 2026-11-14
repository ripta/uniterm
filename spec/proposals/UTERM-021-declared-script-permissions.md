# UTERM-021: Declared Permissions for Script Files

**Status:** draft
**Created:** 2026-11-13
**Updated:** 2026-11-13

## Dependencies

- UTERM-003, for `uniterm run`, the Janet sandbox, and the REPL
- UTERM-004, for controller packages, the review, remembered trust, and the call-boundary check

## Impacts

- UTERM-004 — "Permission scopes and approval flow" and "Controller trust and approval choices": the review's
  per-run choice is named "Allow for This Run", and plain-script questions use the same name. A declared file takes
  the review and trust choices a controller takes.
- UTERM-004 — "Verified artifact and run binding": a single file becomes a second verified artifact beside the
  package, with its own snapshot and version.
- UTERM-003 — "Where scripts run": the app reads and snapshots a script file before the command runs it. The command
  no longer runs the bytes it read itself.

## Summary

A single Janet file states the powers it needs in a first `(declare-permissions ...)` form. uniterm reads that form as
data, snapshots the file, and runs the copy. The review shows the declared powers before any code runs, and a declared
file can be trusted by version or, when signed, by identity. A call outside the declaration is refused. By default
uniterm runs in strict mode, which refuses a file that declares nothing. An unsafe mode lets the user run such a file
for one run. A lint command compares a file's calls with its declaration.

## Motivation

A controller package declares its powers in `controller.json`. uniterm shows them in the review and refuses anything
undeclared. A plain `uniterm run file.janet` has none of that. Nothing is reviewed at start, nothing can be trusted
across runs, and each clipboard use asks on its own. A user cannot tell ahead of time what a plain script will do.

Making every script a package is heavy for a one-file tool. A descriptor, a file list with digests, and a folder are a
lot to ask of a ten-line script. The file can carry its own declaration instead. Enforcement at the call boundary
already fails closed, so the declaration only has to say what to review. It need not prove what the code will call.

The review wording also disagrees with itself. The startup review says "Allow for This Session", and a question row
says "Allow for This Run" or "Allow for This Connection". All three mean one run.

## Design Decisions (Settled)

### The declaration form

Decision: a file declares its powers with `(declare-permissions ...)`, its first form.

```janet
#!/usr/bin/env uniterm run
(declare-permissions {:id "dev.example.tidy" :name "Tidy"}
  {:kind :pane-control :version 1}
  {:kind :clipboard-read :version 1})

(import uniterm)
```

- Only a `#!` line may come before it. A declaration anywhere else is an error.
- It appears exactly once. A second declaration is an error.
- It holds literal data only: keywords, strings, numbers, tuples, and structs. A symbol, a call, a quasiquote, or an
  unquote refuses the file.
- The permissions use `controller.json`'s (kind, version) vocabulary and its rules. An unknown kind or version
  refuses the file, and so does one kind listed twice. A scoped kind, such as a capability or a host launch, is
  listed once for each scope.
- An optional leading struct carries `:id` and `:name`. The ID follows `controller.json`'s ID rules. It is required
  when the file is signed. An unsigned file without a name is shown by its file name.
- uniterm binds `declare-permissions` before the file loads, so a misspelled form fails as an unbound symbol. At run
  time the form expands to nothing.
- The name sits outside the `uniterm/` namespace. A declaration is not a call, and should not read like one.

Rationale: a dedicated form makes a typo fail loudly. A `def` with a well-known name would read as no declaration, and
the file would run as an undeclared script. Literal data can be read without running anything. A form at a fixed
place cannot hide behind code that runs first.

### Authority comes from the read, not the run

Decision: uniterm reads the declaration with Janet's own parser, from the snapshot's bytes, before any of the file
runs. The value the form has at run time grants nothing. Where the parser runs is open; see "Where the declaration is
read".

Rationale: a separate hand-written reader could read a crafted file differently from how the VM reads it. Reading
with the parser that will run the file closes that gap.

### The file is snapshotted and hashed

Decision: the app reads the file, copies it to a private read-only snapshot, and the command runs that copy. The
version is the SHA-256 of the whole file, declaration included.

- A declared file runs alone. Its loader resolves no imports, so a file that needs others must be a package.
- `--allow` names only capabilities the file declares, as it does for a package.

Rationale: an approval must bind to the bytes that were reviewed. Otherwise the file could change between the review
and the run.

### Signing

Decision: a file is signed by a detached `file.janet.sig` beside it. The signature uses `controller.sig`'s scheme, an
Ed25519 signature over a fixed domain line and the file's exact bytes. A signed file's leading struct must carry an
`:id`.

- A signature that does not verify refuses the file. It never falls back to an unsigned version.
- Identity trust pins the public key plus the ID, as it does for a controller.

Rationale: a signature cannot sit inside the bytes it covers. An embedded signature would need byte-exact exclusion
rules, which are easy to get subtly wrong. A sidecar keeps one verifier for packages and files.

### Undeclared powers are refused

Decision: a call that needs a power its file or controller did not declare is refused. The error names the
undeclared permission. uniterm never offers to allow it.

Rationale: strict enforcement is the point of declaring. An offer to allow extra would turn every declaration into a
starting bid.

### Strict and unsafe modes

Decision: a uniterm setting chooses strict or unsafe mode. Strict is the default. A run cannot choose its own mode,
and `uniterm run` takes no flag for it.

| File | Strict | Unsafe |
|---|---|---|
| Declares its powers | Review with Deny, Allow Once, Allow for This Run, Trust This Version, and Trust This Identity when signed | Same |
| Declares nothing | Refused | Review with Reject, Allow and Ask Each Use, Allow Everything |

- Strict mode's refusal says uniterm is in strict mode and names `(declare-permissions ...)`.
- Each unsafe choice lasts one run. An undeclared file has no trust choice. Its review says that adding a declaration
  makes the script trustable.
- Allow and Ask Each Use keeps the behavior plain scripts have today. Clipboard calls ask. Pane calls follow the pane
  rules.
- Allow Everything grants pane control, clipboard read, and clipboard write for the run. The review lists them. They
  stay revocable from the Pending Requests panel and are checked at the call boundary like any grant. A host launch
  has no blanket scope, so it still asks on each use.

Rationale: a declared file can be reviewed, trusted, and enforced. An undeclared file can only be guessed at, so the
default refuses it. The setting belongs to whoever owns uniterm. A flag would let whoever types the command, or a
script that runs `uniterm run` on another file, pick the mode. Remembered trust records (kind, version, scopes), and an
undeclared file has none to record.

### Run wording

Decision: every choice that lasts one run is named "Allow for This Run". That covers the startup review, controller
questions, and plain-script questions, which said "Allow for This Connection".

Rationale: one connection is one run. Three names for one lifetime confused the user in hands-on review.

### The lint

Decision: uniterm ships a lint that scans a file's literal `uniterm/` calls and compares them with its declaration.
It reports calls that need an undeclared power, and declared powers the file never uses. It is best effort and
grants nothing. A dynamic call, such as one built with `symbol` or run through `eval`, makes it report that the file
could make any call. Its name and form are open; see "The lint's name".

Rationale: enforcement makes a missed call safe. It is refused at run time. A lint moves that error to before the run.

### Out of scope

- REPL panes. Code typed into a REPL has no file to declare in. Its powers stay as UTERM-003 and UTERM-004 define.
- Packages. `controller.json` is unchanged, apart from the run wording.

### Version skew

Decision: the change follows UTERM-004's skew rules.

- The command and the app: declared files add a begin message, and ScriptWire's version goes up. Each side refuses any
  other version at the hello, so an older command and a newer app refuse each other before any effect.
- The trust store: a file's version and identity approvals are new records. An older build reading a newer policy file
  authorizes nothing, as UTERM-004 already requires.
- An older build running a declared file fails at load, since it has no `declare-permissions` binding. That fails
  closed.

## Design Decisions (Open)

### Where the declaration is read

The app does not link Janet. Only the command and the REPL helper do.

- **A sandboxed parse helper.** The app passes the snapshot's bytes to a helper under ADR-10's sandbox, and the helper
  returns the declaration as data. It uses Janet's parser and adds no Janet to the app. It adds a helper and its
  protocol.
- **The command reports it.** The authenticated command parses the snapshot and sends the declaration to the app. The
  approval binds to the file's version, and enforcement uses the approved scopes. A command that misreported could
  only change what the review shows for that version. It adds nothing new to the app, but the review's text then
  depends on the command.
- **Janet in the app.** The app links Janet and parses in process. This is simplest, but it puts a C parser for
  untrusted input in the unsandboxed app, which runs against ADR-07 and ADR-10's rationale.

### The declaration's data shape

- Kinds as keywords, `:pane-control`, or as strings matching `controller.json`, `"pane-control"`.
- How a host launch's `executable`, `directory`, and `environment` fields are spelled.
- Whether the declaration carries a format number of its own, or relies on each permission's version.

### The lint's name

- `uniterm lint file.janet`, a command of its own.
- `uniterm run --check file.janet`, which lints and runs nothing.

### Where the mode setting lives

- Which Settings page shows strict and unsafe, and how the unsafe choice is worded there.
- Whether changing the mode affects runs already waiting for review, or only runs that start after the change.

## Risks

- **Strict mode by default refuses every existing plain script** — likelihood: high, impact: medium.
  Mitigation: the refusal says uniterm is in strict mode and names the form to add. The repo's own fixtures and
  examples gain declarations in the same milestone. The setting is one switch away for anyone who needs the old
  behavior.
- **A parser differential lets the review show something other than what runs** — likelihood: low, impact: high.
  Mitigation: the declaration is read with Janet's own parser from the snapshot's bytes. Enforcement uses the approved
  scopes whatever the review showed, so a differential cannot grant an unapproved power.
- **Allow Everything is a blanket grant to code that said nothing** — likelihood: medium, impact: medium.
  Accepted: it exists only in unsafe mode, which the user turns on. It lasts one run, names its three powers, stays
  revocable, and never covers a host launch.
- **The declaration form becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: each permission carries a version, and an unknown kind or version refuses the file. A newer build reads
  older declarations with their own meanings. The open data-shape question settles whether the form needs a format
  number of its own.
- **The trust store gains new record types** — likelihood: high, impact: low.
  Mitigation: an older build reading a newer policy file authorizes nothing, so a downgrade loses trust instead of
  widening it.

## Milestones

### M1: Run wording

**Status:** NOT STARTED

- The startup review, controller questions, and plain-script questions all name their per-run choice "Allow for This
  Run"
- The review's help text and the waiting-runs text use the same name
- A UI test screenshot of the review and of a question row shows the new name

### M2: Declared files

**Status:** NOT STARTED

- A file with a valid declaration shows a review listing its powers before any of its code runs
- A second declaration, a declaration after another form, a non-literal value, an unknown kind or version, and a
  repeated kind each refuse the file with a message naming the problem
- A misspelled form name fails as an unbound symbol
- The command runs the snapshot, and an edit to the file after review does not change what runs
- Trust This Version keeps the next run of the same bytes from asking, and an edited file gets a fresh review
- A call needing an undeclared power is refused, and the error names the permission, for files and controllers
- An older command and a newer app refuse each other at the hello

### M3: Signed files

**Status:** NOT STARTED

- `uniterm controller sign` signs a file and writes `file.janet.sig`
- A signed file offers Trust This Identity, and a new version under a trusted identity that asks for nothing new runs
  without review
- A signature that does not verify refuses the file
- A signed file without an `:id` is refused

### M4: Strict and unsafe modes

**Status:** NOT STARTED

- The setting defaults to strict
- In strict mode, a file without a declaration is refused with a message naming strict mode and the form
- In unsafe mode, such a file shows Reject, Allow and Ask Each Use, and Allow Everything, and none offers trust
- Allow Everything lets pane and clipboard calls run without asking for that run, and a host launch still asks
- Revoking an Allow Everything grant refuses the run's next call
- The repo's script fixtures and examples carry declarations, and the package and UI test suites pass in strict mode

### M5: The lint

**Status:** NOT STARTED

- The lint reports a literal call whose power the file does not declare
- The lint reports a declared power the file never uses
- A file that builds a call name or uses `eval` is reported as able to make any call
- The lint runs none of the file's code

## Decision Log

- 2026-11-13: Drafted from hands-on review of the Pending Requests panel. The user chose an embedded declaration over a
  scanner as authority, and a dedicated form over a `def` for its loud typo behavior. The user chose
  `declare-permissions`, outside the `uniterm/` namespace. The user chose literal data, a single declaration at the
  start, and `controller.json`'s vocabulary.
- 2026-11-13: The user chose a detached `.sig` sidecar for signing, and an optional `:id` and `:name`, required when
  signed.
- 2026-11-13: The user chose strict mode by default, with an unsafe mode whose choices last one run. The user chose an
  app setting with no run flag, and the pane rules for Ask Each Use.
- 2026-11-13: The user chose to refuse undeclared powers outright, with no offer to allow them.
- 2026-11-13: The user chose "Allow for This Run" everywhere, including plain-script questions.
- 2026-11-13 (addition): The user added the lint to this proposal.
- 2026-11-13: The user kept REPL panes out of scope.
- 2026-11-13: ADR candidate (cuts across the system): script files run strict by default, refusing a file that declares
  nothing. Declined: ADR-09 already requires an explicit grant for every effect, and the strict default applies it.
- 2026-11-13: ADR-09 check. Allow Everything is written as a grant of three named powers, revocable and checked at the
  boundary, to match "an explicit, revocable grant covering the operation". An unsigned file's trust is version trust
  only. Identity trust needs a signature and an ID, to match "digests ... are insufficient proof of script identity".

## References

- ADR-07: failure isolation. Scripts still run in the command's process.
- ADR-09: control authority requires authenticated identity and explicit scope.
- ADR-10: helpers that need no file or network access run sandboxed. It bears on where the declaration is read.
