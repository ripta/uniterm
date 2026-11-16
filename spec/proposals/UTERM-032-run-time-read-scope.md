# UTERM-032: Read Scope Granted at Run Time

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-015, for the path-reading power and its checks, built in its M4
- UTERM-004, for controller runs, approval, and revocation
- UTERM-021, for declared files and the `declare-permissions` spelling

## Impacts

- UTERM-030 — "Slide images": slide images load from the folder this proposal grants.
- UTERM-025 — "How it starts": the presenter starts with the deck's folder granted here, and no `:fs-read`.
- UTERM-015 — "How the path-reading power is granted": adds a scope the user names at run time, beside a scope written
  in a controller's file.

## Summary

Lets the user grant a controller read access to one folder when starting it, such as the folder of a deck the user
names. The controller holds no other file access. The app checks every read against that folder.

This is a required prerequisite of the presentation controller, UTERM-025, through its slide images.

## Motivation

A declared file states its powers as fixed text inside the file. A path-reading scope written there names one folder,
for every run. A presenter is started on a different deck each time, usually in Documents or Desktop. A fixed scope
cannot follow it.

The alternative is Janet's `:fs-read`, which reads any file the user can. That is far more than a presenter needs. It
also makes a scoped image read pointless, since the script could read the images itself.

## Design Decisions (Settled)

### The user names the folder at the start

Decision: a controller's file may declare that it takes one folder at run time. The user names the folder when starting
the run, and approves that folder for that run. The controller can then have applets read inside it, under UTERM-015's
checks. It gets no `:fs-read`.

Rationale: the user's choice of deck is the user's act, the same as picking a file in File > Open. Binding the scope to
that choice, for one run, gives the controller the least access that works. The user chose this over sending image
bytes with each slide and over a scope fixed in the file.

### The grant ends with the run

Decision: the folder grant lasts only for that run. Ending, revoking, or a restore ends it, per ADR-09 and ADR-03. A
remembered approval of the controller does not remember the folder.

Rationale: the next run names a different deck.

### The controller reads its input on stdin

Decision: a controller that needs a file's text, such as the presenter's deck, reads it on stdin. The folder grant lets
applets read inside the folder. It never lets the controller read files itself.

Rationale: stdin needs no capability, and the user chooses what goes there. The controller keeps no file access.

## Design Decisions (Open)

### How the user names the folder

- On the command line, such as `uniterm run presenter.janet --folder ~/talks/demo`.
- From the deck file's path, such as `uniterm run presenter.janet ~/talks/demo/deck.md`, granting its parent.
- In the approval sheet, with an open panel.

### Protected folders

UTERM-015 removes protected locations, such as Documents and Desktop, from a scope unless the scope names them. Whether
a folder the user names at run time inside Documents counts as naming it.

### Names

The declaration spelling under UTERM-021, and the command-line or sheet wording.

## Risks

- **A run-time scope is a new approval contract** — likelihood: high, impact: medium. Users and tools would depend on how
  it is named and shown. Mitigation: version the declaration under UTERM-021, and show the folder in the approval sheet.
- **A user names too broad a folder, such as `~`** — likelihood: medium, impact: medium. Mitigation: the approval sheet
  shows the folder, and UTERM-015's protected-location rule still applies.

## Milestones

### M1: Grant a folder at run time

**Status:** NOT STARTED

- A controller that declares a run-time folder starts only after the user names and approves a folder
- An applet read inside the folder succeeds, and one outside it fails with UTERM-015's single error
- The grant ends with the run, and the next run asks again

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose a folder scoped at run time, with the deck
  on stdin, over sending image bytes and over a scope fixed in the file.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
