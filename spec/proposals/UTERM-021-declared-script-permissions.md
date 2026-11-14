# UTERM-021: Declared Permissions for Script Files

**Status:** accepted
**Created:** 2026-11-13
**Updated:** 2026-11-14

## Dependencies

- UTERM-003, for `uniterm run`, the Janet sandbox, and the REPL
- UTERM-004, for controller packages, the review, remembered trust, and the call-boundary check

## Impacts

- UTERM-004 — "Permission scopes and approval flow" and "Controller trust and approval choices": the review's
  per-run choice is named "Allow for This Run", and plain-script questions use the same name. A declared file takes
  the review and trust choices a controller takes.
- UTERM-004 — "Verified artifact and run binding": a single file becomes a second verified artifact beside the
  package, with its own snapshot and version.
- UTERM-003 — "Where scripts run": the app reads and snapshots a declared script file before the command runs it. The
  command runs the snapshot, not the bytes it read itself. An undeclared file is not snapshotted, and its run waits
  for the app's answer. `uniterm run` no longer sends the plain begin.

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
#!/usr/bin/env -S uniterm run
(declare-permissions {:id "dev.example.tidy" :name "Tidy"}
  {:kind :pane-control :version 1}
  {:kind :clipboard-read :version 1})

(import uniterm)
```

- Only a `#!` line, comments, and whitespace may come before it. A declaration anywhere else is an error. A comment
  cannot hide code, since the parser skips it.
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
runs. The value the form has at run time grants nothing. "Where the declaration is read" says which process runs the
parser.

Rationale: a separate hand-written reader could read a crafted file differently from how the VM reads it. Reading
with the parser that will run the file closes that gap.

### The file is snapshotted and hashed

Decision: the app reads the file, copies it to a private read-only snapshot, and the command runs that copy. The
version is the SHA-256 of the whole file, declaration included.

- A declared file runs alone. Its loader resolves only uniterm's bundled modules, as a package's does, and no file. A
  script that needs other files must be a package.
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

Decision: a call from a declared file or a controller that needs a power it did not declare is refused. The error names the
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
- Once the run starts, Allow and Ask Each Use keeps the call behavior plain scripts have today. Clipboard calls ask.
  Pane calls follow the pane rules. The review before the run is new, so an undeclared file in unsafe mode asks once
  per run where today it asks nothing at start.
- Allow Everything grants clipboard read and clipboard write for the run. Pane calls follow the pane rules under both
  choices, so the clipboard is the only difference. The review lists the two powers and any `--allow` capabilities.
  The grants stay revocable from the Pending Requests panel and are checked at the call boundary like any grant. A
  host launch has no blanket scope, so it still asks on each use.
- Strict mode is a policy for the `uniterm` command, not a boundary against other programs. A generic peer that is not
  the bundled command keeps the admission UTERM-004 gives it. The app tells the two apart by authenticating the peer,
  as it does for packages. ADR-09 already places other processes of the same user outside what uniterm defends
  against.
- An undeclared file is not snapshotted. The command reads and runs it, so `uniterm run <(...)` still works in unsafe
  mode. The command does not start it until the app answers. It sends an undeclared begin naming the file and the
  `--allow` capabilities, and waits for admitted, refused, or reviewing, as a package run waits. A generic peer's plain
  begin stays as UTERM-004 has it, with no answer.

Rationale: a declared file can be reviewed, trusted, and enforced. An undeclared file can only be guessed at, so the
default refuses it. The setting belongs to whoever owns uniterm. A flag would let whoever types the command, or a
script that runs `uniterm run` on another file, pick the mode. Remembered trust records (kind, version, scopes), and an
undeclared file has none to record.

### Run wording

Decision: every choice that lasts one run is named "Allow for This Run". That covers the startup review, controller
questions, and plain-script questions, which said "Allow for This Connection". A REPL pane's questions and a generic
peer's keep "Allow for This Connection", since neither connection is a run.

Rationale: a plain script's connection is its run. Three names for one lifetime confused the user in hands-on review.

### The lint

Decision: uniterm ships a lint that scans a file's literal `uniterm/` calls and compares them with its declaration.
It reports calls that need an undeclared power, and declared powers the file never uses. It is best effort and
grants nothing. A dynamic call, such as one built with `symbol` or run through `eval`, makes it report that the file
could make any call. "The lint's name" says how it is invoked.

Rationale: enforcement makes a missed call safe. It is refused at run time. A lint moves that error to before the run.

### Where the declaration is read

Original question: the app does not link Janet, and ADR-07 keeps Janet out of it. Which process parses the
declaration: a new sandboxed parse helper, the authenticated command, or a Swift reader in the app?

Decision: the authenticated command parses the snapshot and reports the declaration to the app.

- The command reads the file. When its first form is a declaration, the command resolves the file's path and sends a
  file begin. Otherwise it sends an undeclared begin, which strict mode refuses before any code runs. What the command read only routes the
  run. The snapshot's parse decides what is declared. The app reads the file and refuses anything but a
  regular file within a size cap. It hashes and snapshots the file and verifies any `.sig`. It answers with the
  snapshot and the version.
- The command checks the snapshot's hash, then parses its first form with the Janet it will run. It converts the
  declaration to `controller.json`'s permission structure and sends it.
- The app validates the declaration with the strict permission reader packages use, looks up trust by the version,
  and reviews or admits the run.
- A parser exploit inside the declaration runs in the unsandboxed command before the review. That is no worse than
  the whole-file parse after approval, which no option can sandbox, since ADR-10 keeps the command outside the App
  Sandbox.

Rationale: the same parser reads the same bytes, so no differential is possible. The app already trusts the
authenticated command to apply the Janet sandbox and to run the snapshot it was given. A sandboxed parse helper
protects only a parse the attacker can route around, by putting the exploit in the second form, and it adds a helper,
a wire protocol, and entitlements. A Swift reader would be a second Janet grammar to keep in step with every Janet
release, and its run-time cross-check never fires when the two readers disagree about where the first form starts.
Linking Janet into the app breaks ADR-07 and `scripts/check-janet-isolation.sh`.

### One run per command process

Decision: the app accepts one session per command process. A begin from a process that already has a run admitted,
waiting, or refused, or a REPL attached, is refused, whether it begins a plain file, a declared file, or a package.

- A native entry is the exception. Once `uniterm controller run` execs it, the whole process is the controller, so
  every connection of that exec generation is adopted as today.

Rationale: the command opens its session before any script code runs, so a later begin from that process comes from
script code. A script granted a way to reach the socket, such as `net-connect`, could otherwise begin a trusted file
or package on a second connection, and run its own code under that run's standing powers. With the command reporting
the declaration, it could also put a forged declaration in front of the user under another file's verified identity.
The rule covers packages as well as files, since the same second connection could begin a trusted package. It
covers a REPL helper too, since code typed or pasted into a REPL granted `net-connect` could do the same.

### The declaration's data shape

Original question: should kinds be keywords or strings, how are host-launch fields spelled, and does the declaration
carry a format number?

Decision: field names are spelled as `controller.json`'s keys. Closed sets are keywords, and free text is strings.

```janet
(declare-permissions {:id "dev.example.tidy" :name "Tidy"}
  {:kind :pane-control :version 1}
  {:kind :capability :version 1 :name :fs-read}
  {:kind :host-launch :version 1 :executable "/usr/bin/git" :directory "/Users/me/src"
   :environment ["HOME" "PATH"]})
```

- Kinds and capability names are keywords. Janet's own `sandbox` spells capabilities as keywords.
- The ID, the name, paths, and environment keys are strings. Versions are whole numbers.
- The header is the leading struct without a `:kind`.
- There is no format number. An unknown field or kind refuses the file, so an older build fails closed on a newer
  declaration. A later change to the header adds a `:format` key, whose absence means today's shape.
- A proposal that adds a permission kind also defines its declaration spelling: which fields are keywords and which
  are strings.

Rationale: keywords are how Janet spells a closed set. The conversion to `controller.json` keeps each spelling, so it
is a mechanical step. A required format number would make the optional header required, and it guards against no
failure that refusing unknown fields does not already catch.

### Trust records for files

Decision: file approvals live in their own policy file, beside the controller policy file, with their own selectors.

- A file's version selector names the file's SHA-256 alone, so an unsigned file needs no ID.
- A file's identity selector names the ID and the key fingerprint. It never matches a package, and a package's never
  matches a file, even with the same ID and key.
- The file uses the controller policy file's strict reader, its newer-format rule, and its own record limit.

Rationale: the controller policy reader moves aside a file whose selector kind it does not know. Writing file records
into it would make an older build, on downgrade or running beside a newer one, move it aside and lose every controller
approval. A separate file leaves an older build's controller trust working and its file trust simply absent. Separate
selectors keep a signed file from running under a package's identity approval. Every edit of a file is a new version,
so a separate limit also keeps file approvals from crowding out controller approvals.

### Capabilities that load native code

Decision: a declared file cannot declare `ffi`, `ffi-define`, `ffi-jit`, `ffi-use`, or `modules`, the same as a package.
A script that needs one runs only as an undeclared file in unsafe mode, with `--allow` as today.

Rationale: native code loaded at run time escapes the snapshot an approval binds to. Strict mode therefore has no way
to run such a script, and says so in its refusal.

### The lint's name

Original question: is the lint `uniterm lint file.janet`, or `uniterm run --check file.janet`?

Decision: `uniterm lint file.janet`, a command of its own beside `run`. It parses and scans, runs none of the file's
code, and never contacts the app.

Rationale: everything after the script's path in `uniterm run` belongs to the script. A misplaced `--check` would then
run the code it was meant to lint, and a shebang run passes it the same way. Putting the lint under `uniterm
controller` would group it with signing and keys, which are about who wrote a file, not what it calls. Covering
packages is out of scope.

### Where the mode setting lives

Original question: which Settings page shows strict and unsafe, and does a change affect runs already waiting?

Decision: a choice row on the Settings page, "Script files", with Strict and Unsafe. A missing or unknown stored value
reads as strict.

- Switching to strict refuses every waiting undeclared-file review, with a message naming strict mode. An admission or
  an answer that finishes after the switch is refused too.
- A live undeclared run keeps running after a switch to strict. The user ends it with Revoke.
- Switching to unsafe affects runs that start afterward.
- Strict mode's refusal names the Settings row.

Rationale: settings live on the Settings page, and the refusal can point there. An undeclared file never has a
remembered approval, so the Controllers & Permissions window would put the row beside nothing it governs. A switch to
strict that left a waiting review answerable would let the user grant Allow Everything against the policy they just
chose. The code already takes that stance: a trust removal during admission sends the run to review. A same-user
process can change the stored value. ADR-09 already places other processes of the same user outside what uniterm
defends against, and unsafe mode still asks the user before anything runs.

### Out of scope

- REPL panes. Code typed into a REPL has no file to declare in. Its powers stay as UTERM-003 and UTERM-004 define.
- Packages. `controller.json` is unchanged, apart from the run wording.

### Version skew

Decision: the change follows UTERM-004's skew rules.

- The command and the app: declared files add a file begin and a declaration message, and undeclared files add an
  undeclared begin with an answer. ScriptWire's version goes up. Each side refuses any
  other version at the hello, so an older command and a newer app refuse each other before any effect.
- The trust store: a file's version and identity approvals are new records in their own policy file. The controller
  policy file's format and records are unchanged.
- An older build running a declared file fails at load, since it has no `declare-permissions` binding. That fails
  closed.
- An older build never reads the file policy file, so its controller trust keeps working. A newer build reads an
  older one's controller policy file unchanged.
- An older build ignores the mode setting and runs undeclared files as it does today.

## Design Decisions (Open)

None.

## Risks

- **Strict mode by default refuses every existing plain script** — likelihood: high, impact: medium.
  Mitigation: the refusal says uniterm is in strict mode, names the form to add, and names the Settings row. The
  repo's own fixtures and examples gain declarations in the same milestone. Unsafe mode runs an undeclared file after
  one review per run. A declaration plus Trust This Version removes the review until the file changes. No setting
  restores today's run with no review at all, which is the point of the change.
- **A parser differential lets the review show something other than what runs** — likelihood: low, impact: high.
  Mitigation: the declaration is read with Janet's own parser from the snapshot's bytes. Enforcement uses the approved
  scopes whatever the review showed, so a differential cannot grant an unapproved power.
- **Allow Everything is a blanket grant to code that said nothing** — likelihood: medium, impact: medium.
  Accepted: it exists only in unsafe mode, which the user turns on. It lasts one run, names its two powers, stays
  revocable, and never covers a host launch.
- **The declaration form becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: each permission carries a version, and an unknown kind or version refuses the file. A newer build reads
  older declarations with their own meanings. A later header change adds a `:format` key, whose absence means
  today's shape.
- **The trust store gains new record types** — likelihood: high, impact: low.
  Mitigation: file records live in their own policy file, which an older build never reads. A downgrade loses file
  trust and keeps controller trust, so trust is lost instead of widened.
- **Strict mode does not stop a generic peer** — likelihood: medium, impact: low.
  Accepted: a same-user program that is not the bundled command keeps UTERM-004's admission, so it can run undeclared
  code against uniterm in strict mode. ADR-09 already places such programs outside what uniterm defends against.
  Strict mode keeps the user from running an undeclared file through `uniterm run` by accident, which is its purpose.
- **Permission kinds that other proposals add need a declaration spelling** — likelihood: high, impact: low.
  Mitigation: the data-shape decision requires each proposal that adds a kind to define its spelling. An unknown kind
  refuses the file, so a kind that lands without one cannot be declared, and nothing is granted by mistake.
- **A user who trusts every edit of a file piles up version records** — likelihood: medium, impact: low.
  Accepted: file approvals have their own limit, so they cannot crowd out controller approvals. Saving past the limit
  fails with a message, and Revoke clears old versions in the Controllers & Permissions window.

## Milestones

### M1: Run wording

**Status:** NOT STARTED

- The startup review, controller questions, and plain-script questions all name their per-run choice "Allow for This
  Run"
- The review's help text and the waiting-runs text use the same name
- A UI test screenshot of the review and of a question row shows the new name
- A REPL pane's questions and a generic peer's still say "Allow for This Connection"

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
- A file reached through a symlink runs, and a pipe, a device, or a file over the size cap is refused
- The command refuses a snapshot whose hash differs from the version the app sent, before parsing it
- A duplicate key in a struct, `nil`, `true`, `false`, a parenthesized tuple, and a fractional version each refuse the
  file, although Janet's parser would merge or drop them. The check reads the same parser's state before each struct
  closes, and can only refuse
- An empty declaration, `(declare-permissions {:name "x"})`, runs with no powers beyond posting status
- The command runs the bytes it hashed, not a second read of the snapshot, and `(dyn :args)` starts with the original
  path
- A call before admission is refused, as for a controller
- A file begin whose declaration never arrives is refused after a bound
- A first form that is a near miss of the declaration is refused with a message that the declaration must come first
- A signed file and a package with the same ID and key do not share an identity approval
- An older build opening a policy folder that holds file approvals keeps its controller approvals
- A permission whose misspelled `:kind` reads as the header is refused with a message naming the likely typo
- A declared file that declares `ffi`, `ffi-define`, `ffi-jit`, `ffi-use`, or `modules` is refused
- A second begin from a process that already has a run or a REPL attached is refused, for files and for packages. A
  generic peer that already has a plain session can still open another, as UTERM-004 allows
- A peer that is not the bundled command and sends a file begin is refused before any snapshot is made
- A file begin whose snapshot's first form is not a declaration is refused, not run as undeclared
- `(import ./x)` from a declared file finds nothing
- File approvals appear in the Controllers & Permissions window, and Revoke removes them
- The file policy file's kept-aside copies and temporary files are named apart from the controller policy file's
  `policy.aside-*.json` and `policy.json.tmp-*`, so neither store prunes or sweeps the other's
- Every connection a native entry opens after `uniterm controller run` execs it is still admitted

### M3: Signed files

**Status:** NOT STARTED

- `uniterm controller sign` signs a file and writes `file.janet.sig`
- A signed file offers Trust This Identity, and a new version under a trusted identity that asks for nothing new runs
  without review
- A signature that does not verify refuses the file
- A signed file without an `:id` is refused
- The file signature's domain line differs from the controller descriptor's, so a package signature never verifies a
  file
- A valid `.sig` beside an undeclared file grants no identity

### M4: Strict and unsafe modes

**Status:** NOT STARTED

- The setting defaults to strict
- In strict mode, a file without a declaration is refused with a message naming strict mode and the form
- In unsafe mode, such a file shows Reject, Allow and Ask Each Use, and Allow Everything, and none offers trust
- The unsafe review lists the run's `--allow` capabilities
- A generic peer that is not the bundled command keeps UTERM-004's admission in strict mode
- An undeclared file runs none of its code, with or without `--allow`, until the app admits it; strict mode refuses it
  before its first form runs
- In unsafe mode, an undeclared file with a later `(declare-permissions ...)` form is refused before any of its code
  runs
- The app refuses a plain begin from a peer it authenticates as the bundled command
- A request on an undeclared-begin connection before admission is refused
- Allow Everything lets clipboard calls run without asking for that run, and a host launch still asks
- Revoking an Allow Everything grant refuses the run's next call
- Switching to strict refuses every waiting undeclared-file review with a message naming strict mode
- An admission in flight, or a review answer, that finishes after a switch to strict is refused
- A live undeclared run keeps running after a switch to strict, and Revoke ends it
- A missing or unknown stored mode reads as strict
- The repo's script fixtures and examples carry declarations, and the package and UI test suites pass in strict mode

### M5: The lint

**Status:** NOT STARTED

- The lint reports a literal call whose power the file does not declare
- The lint reports a declared power the file never uses
- A file that builds a call name or uses `eval` is reported as able to make any call
- The lint runs none of the file's code
- `(use uniterm)`, `(import uniterm :as u)`, an alias of a `uniterm/` function, and a macro defined in the file are
  each resolved or reported as able to make any call
- A declared capability is never reported as unused, since its uses are Janet's own functions
- The lint maps calls to powers with the same table the app uses at the call boundary

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
- 2026-11-13: Review start: 5 milestones, 10 settled decisions, 5 risks, no Live after lines or row gates; out of
  scope: REPL panes and packages; at commit "Draft UTERM-021: declared permissions for script files". The user asked
  for an autonomous review of the four open questions.
- 2026-11-14 (autonomous): The authenticated command parses the snapshot and reports the declaration. A sandboxed
  parse helper protects only a parse an attacker routes around, a Swift reader adds a second grammar, and Janet in the
  app breaks ADR-07. Converged in 1 pass.
- 2026-11-14 (autonomous): One run per command process, so script code on a second connection cannot begin a trusted
  file under its standing powers or forge the declaration a review shows. Found in the first critique pass.
- 2026-11-14 (autonomous, addition): The one-run rule covers packages too. A second connection can begin a trusted
  package today and run under its standing powers without review. This brings in a refusal for packages, a gap the
  proposal exposes but does not create.
- 2026-11-14 (autonomous): Closed sets are keywords, including capability names, and free text is strings, with no
  format number. Converged in 1 pass.
- 2026-11-14 (autonomous): A declared file cannot declare capabilities that load native code, as a package cannot. A
  script that needs one runs only undeclared in unsafe mode. Found in the first critique pass.
- 2026-11-14 (autonomous): The lint is `uniterm lint file.janet`. `run --check` would run the script when the flag
  lands after the path. Converged in 1 pass.
- 2026-11-14 (autonomous): The mode is a "Script files" row on the Settings page. A switch to strict refuses waiting
  undeclared-file reviews. Converged in 1 pass.
- 2026-11-14 (autonomous): Coherence pass. Strict mode governs the bundled command only. Generic peers keep UTERM-004's
  admission, and undeclared files keep today's unsnapshotted path. Refusing every plain begin would have broken
  generic peers that UTERM-004 keeps, for no gain under ADR-09's same-user limit.
- 2026-11-14 (autonomous): Coherence pass. File approvals get their own policy file and selectors. The controller
  policy reader moves aside a file with an unknown selector kind, so shared records would cost an older build every
  controller approval.
- 2026-11-14 (autonomous, addition): Coherence pass. The one-session rule counts a REPL attach, so pasted REPL code
  with `net-connect` cannot begin a trusted run. This extends the package addition to REPL helpers, which are
  otherwise out of scope.
- 2026-11-14 (autonomous): Coherence pass. A native entry's connections after exec are all adopted, since the whole
  process is the controller.
- 2026-11-14 (autonomous): Coherence pass. Allow Everything grants the two clipboard powers only. Pane calls already
  follow the pane rules under Ask Each Use, so listing pane control claimed a difference that does not exist.
- 2026-11-14 (autonomous): Coherence pass. Comments may precede the declaration, a declared file's loader resolves
  uniterm's bundled modules, REPL and generic-peer questions keep "Allow for This Connection", and the example's
  shebang uses `env -S`. The undeclared-power rule now names declared files and controllers only. Fourteen
  implementation findings went to milestone checks: M1 got 1, M2 got 7, M3 got 2, M4 got 2, M5 got 2.
- 2026-11-14 (autonomous): Re-check pass. An undeclared run from the bundled command sends an undeclared begin and
  waits for the app's answer before running anything. Today's plain begin gets no answer, so a file would have run
  before strict mode refused it or the unsafe review was answered. A generic peer's plain begin is unchanged. Eight
  implementation findings went to milestone checks: M2 got 6, M4 got 2.
- 2026-11-14 (autonomous): Risk review. Added the accepted risk that strict mode does not stop a generic peer, under
  ADR-09's same-user limit. The ScriptWire bump and the new file policy file are versioned, so neither is an
  unlisted one-way door. No risk is rated high likelihood and high impact.
- 2026-11-14 (autonomous): Second re-check pass converged. Three implementation findings went to M4 and one widened
  an M2 check. The Impacts line for UTERM-003 now says undeclared runs wait for the app's answer.
- 2026-11-14: Review gate: kept all, including both one-session additions for packages and REPL helpers.
- 2026-11-14: The user accepted the proposal.
- 2026-11-14: ADR candidate (cuts across the system): one session per command process, for files, packages, and REPL
  helpers. Declined: ADR-09's authenticated binding to the actual run already covers it.

## References

- ADR-07: failure isolation. Scripts still run in the command's process.
- ADR-09: control authority requires authenticated identity and explicit scope.
- ADR-10: helpers that need no file or network access run sandboxed. It bears on where the declaration is read.
