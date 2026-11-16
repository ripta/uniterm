# UTERM-033: Reclaim a Restored Group

**Status:** draft
**Created:** 2026-11-16
**Updated:** 2026-11-16

## Dependencies

- UTERM-004, for groups, saved layouts, the badge's Give Group, and layout requests
- UTERM-021, for a declared file's identity

## Impacts

- UTERM-004 — "Saved layouts": adds a second way to make the explicit grant it requires. A controller run asks to adopt
  a restored group, and the user approves. The badge's Give Group stays. The saved group gains the identity of the
  controller that made it, as a hint that grants nothing, so the layout envelope's version goes up.
- UTERM-025 — "Slides only, beside the terminal": a presenter run after a relaunch reuses its restored slide pane instead
  of opening a second one.

## Summary

Lets a controller that runs again after a relaunch take back the group its earlier run left, with the user's approval.
Its layout request then places the restored panes instead of opening new ones. This is a nice-to-have. The presenter
works without it.

## Motivation

A restored layout keeps a controller's group as placement only, with no owner, per UTERM-004 "Saved layouts". The
controller does not run, per ADR-03. When the user runs it again, it is a new connection that owns nothing. It cannot
see the restored group, command it, or close it. Its layout request opens a new group beside the old one.

For the presenter, that leaves a stale slide pane, which says its content came from a program and was not restored,
beside the live one. The user can give the group back from its badge, but the script cannot ask for that, and does not
know the group exists.

## Design Decisions (Settled)

### No signal at restore

Decision: nothing tells a controller that its group was restored. The offer comes only when the controller runs again.

Rationale: a restored layout runs no program, per ADR-03, so no controller is running to signal.

### The user approves every adoption

Decision: a run adopts a restored group only after the user approves. Adoption grants the run the restored member set
and nothing more. The members' saved desired modes still need enabling, as for Give Group.

Rationale: UTERM-004 and ADR-09 require an explicit grant before a new connection gains restored authority.

### From the group's source pane only

Decision: only a run from the restored group's source pane may ask to adopt it.

Rationale: the source pane is where the earlier run started, and UTERM-004 keeps groups anchored to it. A run elsewhere
in the window has no tie to the group.

### The group records its controller

Decision: a saved group records the identity of the controller that made it. A run is offered the group only when its
verified identity matches. The record is a hint. It grants nothing, and the user still approves every adoption.

- The record changes the layout envelope, so its version goes up under ADR-06. An older build keeps a newer file aside.
- The record is display and matching data only. Authority comes from the run's fresh verified binding and the user's
  approval, per ADR-09.

Rationale: without a record, any run from the source pane could be offered any restored group. UTERM-004 records no
reason for leaving the identity out. Its rules are that a restored layout grants no authority and that a grant binds a
current verified identity. A hint that grants nothing keeps both. ADR-09 says a saved name is no proof of identity,
which is why the hint only narrows the offer, and never stands in for verification. The user chose to track the group.

## Design Decisions (Open)

### What the record holds

A declared file's `:id` is optional under UTERM-021. Options for a file without one: its content hash, which changes on
every edit, or no record, so the file cannot reclaim. A package's identity is its controller ID. Also: whether a
different version of the same controller matches.

### How the run learns of the group

- A call that lists the restored groups on the run's source pane.
- The layout request's reply offers adoption when an ownerless group sits on the source pane.

### What the user sees

A sheet when the run asks, or an offer on the group's badge. How it names the group and its members.

### Partial and changed groups

What happens when the user closed some members, changed a member's applet, or several restored groups share the source
pane.

### Undeclared runs

Whether a bare terminal-session caller may ask. ADR-09 gives it no persistent approval, since its identity cannot be
verified.

## Risks

- **A different controller adopts a group meant for another** — likelihood: medium, impact: medium. Mitigation: the user
  approves every adoption, and the sheet shows what the group holds.
- **The identity record is a layout schema change** — likelihood: high, impact: medium. Mitigation: follow ADR-06's
  versioning, and treat the record as display data that grants nothing.
- **A forged record steers the offer** — likelihood: low, impact: low. A program that edits the layout file can make a
  group match another controller. Accepted: the record grants nothing, the run must still verify, and the user
  approves.

## Milestones

### M1: Adopt a restored group

**Status:** NOT STARTED

- After a relaunch, a run from the source pane asks to adopt the restored group, the user approves, and its layout
  request places the restored panes with no new pane
- A denied request leaves the group ownerless, and the run's layout opens new panes as today
- A run from another pane is never offered the group
- A run whose verified identity does not match the group's record is never offered it
- An older build keeps a layout file with the record aside, unchanged

## Decision Log

- 2026-11-16: Filed as a nice-to-have. The user chose it after asking whether a restored presenter duplicates panes. It
  does today: a new run opens a second group beside the restored one.
- 2026-11-16: The saved group records the controller that made it, as a hint that grants nothing. The user said the
  group needs tracking. The previous text claimed UTERM-004 saves no such record by design. UTERM-004 records no reason
  for that, and nothing in it or ADR-09 forbids a record that grants nothing.

## References

- ADR-03: restored state never runs a program
- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
