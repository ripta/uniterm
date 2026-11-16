# UTERM-033: Reclaim a Restored Group

**Status:** draft
**Created:** 2026-11-16
**Updated:** 2026-11-16

## Dependencies

- UTERM-004, for groups, saved layouts, the badge's Give Group, and layout requests
- UTERM-021, for a declared file's identity

## Impacts

- UTERM-004 — "Saved layouts": adds a second way to make the explicit grant it requires. A controller run asks to adopt
  a restored group, and the user approves. The badge's Give Group stays. If the saved group comes to record which
  controller made it, that supersedes in part the rule that a grant binds current identities, not historical file
  claims.
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

## Design Decisions (Open)

### How a run matches a group

UTERM-004 saves no record of who made a group. Options:

- **No identity match.** Any run from the source pane may ask, and the sheet shows what the group holds. Simplest, and
  needs no saved data.
- **Save the controller's identity as a hint.** The saved group records the declared file's ID or the package's
  identity. Only a matching run is offered the group. The hint grants nothing, and the user still approves. This changes
  the layout envelope under ADR-06, and supersedes in part UTERM-004's rule on historical claims.

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
- **A saved identity hint is a layout schema change** — likelihood: medium, impact: medium, if chosen. Mitigation: follow
  ADR-06's versioning, and treat the hint as display data that grants nothing.

## Milestones

### M1: Adopt a restored group

**Status:** NOT STARTED

- After a relaunch, a run from the source pane asks to adopt the restored group, the user approves, and its layout
  request places the restored panes with no new pane
- A denied request leaves the group ownerless, and the run's layout opens new panes as today
- A run from another pane is never offered the group

## Decision Log

- 2026-11-16: Filed as a nice-to-have. The user chose it after asking whether a restored presenter duplicates panes. It
  does today: a new run opens a second group beside the restored one.

## References

- ADR-03: restored state never runs a program
- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
