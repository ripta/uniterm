# UTERM-032: Input File Granted at Run Time

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-16

## Dependencies

- UTERM-015, for the path-reading power, its checks, and its approval lifetimes, built in its M4
- UTERM-003, for `uniterm run` and its argument handling
- UTERM-004, for controller runs, the approval panel, and revocation
- UTERM-021, for declared files and the `declare-permissions` spelling

## Impacts

- UTERM-030 — "Slide images": slide images load from the folder this proposal grants.
- UTERM-025 — "How it starts": the presenter takes its deck as an argument, under this proposal.
- UTERM-004 — "Permission scopes and approval flow": supersedes in part its rule that approvals hold typed authority
  ceilings, not exact launch inputs, and that arguments are never part of a remembered scope. A remembered folder for
  slide images comes from a run's argument. UTERM-004 is implemented, so it gains a "Superseded in part by UTERM-032"
  marker when this proposal is accepted.
- UTERM-004 — M6's approval panel: it gains a line naming the input file's folder when no remembered approval covers
  the folder.
- UTERM-021 — "The declaration's data shape": a declared file gains a field naming its input argument.
- UTERM-015 — "How the path-reading power is granted": adds a folder that comes from a run's argument, beside a scope
  written in a controller's file.

## Summary

A declared script may name one argument as its input file, such as the presenter's deck:
`uniterm run presenter.janet ~/talks/demo/deck.md`. uniterm reads the file and hands its text to the script. After the
user approves, the script may have the text viewer load images from that file's folder. The script itself holds no file
access.

This is a required prerequisite of the presentation controller, UTERM-025, through its deck and slide images.

## Motivation

A declared file states its powers as fixed text inside the file. A path-reading scope written there names one folder,
for every run. A presenter is started on a different deck each time, usually in Documents or Desktop. A fixed scope
cannot follow it.

The alternative is Janet's `:fs-read`, which reads any file the user can. That is far more than a presenter needs.

## Design Decisions (Settled)

### The deck is an argument

Decision: a script's declaration may mark one argument as its input file. The user names the file when starting the
run. uniterm reads it and gives the script its text. After approval, the app grants the file's folder for the run.

- The argument still belongs to the script, per `uniterm run`'s rule that everything after the script's file is the
  script's. The script reads the path from its arguments, so it knows the folder it may pass to the viewer.
- One name drives both the text and the folder, so a deck cannot mismatch its images.
- A script that declares no input file runs as it does today.

Rationale: the user names the deck as an argument, the way any command takes a file. The script gets the text it needs
and no file access.

### Approval shows the folder

Decision: the approval sheet names the input file's folder. That is where the authority comes from.

Rationale: a name on a command line can come from a program, per UTERM-015's rule that a program can choose what a
command line names. So the run's argument is not the user's act by itself. The sheet is.

### The grant covers slide images only

Decision: the folder grant lets the text viewer load a slide's images from inside the folder, under UTERM-030. It grants
no other path read, even after other path commands land under UTERM-015 M4.

Rationale: the presenter needs only images. A wider grant would widen silently as other applets gain path commands.

### Approval lifetimes

Decision: the user chooses Allow once, for the session, or remember, as for UTERM-015's other path grants. A remembered
approval covers the same folder, or one inside it, on later runs, per ADR-09's reuse rule. A different folder asks again.

Rationale: rehearsing a talk runs the same deck many times. Asking every run trains the user to approve without
reading, which ADR-09's Context warns against. The user chose this.

### Protected folders

Decision: UTERM-015's protected-location rule applies as written. A folder inside Documents keeps its access, and the
sheet names Documents.

Rationale: UTERM-015 "How the path-reading power is granted" removes only protected locations inside a scope, and names
any protected location the scope lies in.

### Version skew

Decision: the declaration field and the folder crossing from the command to the app are new, so ScriptWire's version goes
up.

- A new command with an old app, or the reverse, fails at the hello before any effect, with the message to relaunch
  uniterm. The command is the bundle's own, so a relaunch heals it.
- An older build refuses a declared file that marks an input file, since it does not know the field.
- A remembered approval of such a file makes an older build treat the whole policy file as newer, so every remembered
  approval goes inert until the user is back on the new build. That fails closed, as in UTERM-024 "Version skew".

## Design Decisions (Open)

### Which argument is the input file

A position, the last argument, or a named flag such as `--deck`. A position breaks when a script later adds an option
before it. Also: what happens when the argument is missing. The choice is a published contract under UTERM-021, which
refuses unknown fields.

### How the text reaches the script

- **The command opens the file onto the script's stdin** before the script runs. The read happens in the invoker's own
  process, with the invoker's own access, so it borrows nothing from uniterm. Janet reads stdin with no capability.
- **A host call returns the input file's text.** The app reads a path a program chose, with uniterm's macOS privacy
  grants. Combined with a remembered approval, a later run by any program could read a file under the folder without a
  sheet. UTERM-015 gives program-chosen command-line paths no remembered approval for this reason. If chosen, the read
  must come after approval, follow UTERM-015 M4's open rules, and count as a path read in the sheet and the risks.

Either way, a missing file, a non-regular file, a FIFO, or a `/dev/fd` path is refused before anything blocks, and
before any sheet names it.

### How the script names the base folder

The script cannot reliably name the canonical folder UTERM-030 checks. A relative argument has no folder part, and
`os/realpath` needs `:fs-read`. Options:

- **The host fills in the base folder** from the run's grant, and the script passes nothing or a path relative to it.
- **A host call returns the canonical input path.**

### The stored approval

A remembered folder needs its own stored record kind, apart from UTERM-015's path-reading power, since UTERM-015
refused one stored type with two meanings. Also its coverage rule, with UTERM-015's protected-location subtraction, so a
remembered `~` does not cover a deck under `~/Documents`.


### Names

The declaration field's spelling under UTERM-021, and the sheet's wording.

## Risks

- **An input file is a new approval contract** — likelihood: high, impact: medium. Users and tools would depend on how
  it is declared and shown. Mitigation: version the declaration under UTERM-021, and show the folder in the sheet.
- **A user names a deck in too broad a folder, such as `~`** — likelihood: medium, impact: medium. Mitigation: the sheet
  shows the folder, UTERM-015's protected-location rule still applies, and the grant covers slide images only.
- **A program-started run reuses a remembered folder** — likelihood: medium, impact: high. Any process can run
  `uniterm run` with a path under a remembered folder. Mitigation: settle "How the text reaches the script" so the read
  borrows nothing, and the grant covers slide images only.
- **The stored approval changes shape** — likelihood: high, impact: medium. Remembered scopes start holding a value from
  a run's argument. Mitigation: a record kind of its own, versioned with the policy file. See "The stored approval".
- **Downgrading leaves every remembered approval inert** — likelihood: low, impact: medium. Accepted: it fails closed,
  and the approvals come back on the new build.

## Milestones

### M1: An input file granted at run time

**Status:** NOT STARTED

- A script that declares an input file gets the named file's text and no file access of its own
- The approval sheet names the file's folder, and the run starts only after approval
- A missing, non-regular, FIFO, or `/dev/fd` input is refused before anything blocks
- A remembered approval covers a later run on the same folder, and a different folder asks again
- A remembered `~` does not cover a deck under `~/Documents`
- The grant ends with the run, whatever the approval lifetime, and covers the deck's own canonical folder
- No path read other than slide images succeeds under the grant
- UTERM-030 M2 builds on this milestone and owns the image checks

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose a folder granted at run time, with no
  `:fs-read`, over sending image bytes and over a scope fixed in the file.
- 2026-11-16: The deck is an argument, and uniterm hands the script its text. The user corrected the previous text,
  which had the deck arrive on stdin with the folder named separately. That text came from option wording the agent
  wrote. It left the deck and its folder unbound, so images could not load.
- 2026-11-16: Approval lifetimes follow UTERM-015. The user chose this over asking every run.
- 2026-11-16 (agent): the grant covers slide images only. A grant of UTERM-015's whole power would widen silently as
  other applets gain path commands.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-10: helper sandboxing
