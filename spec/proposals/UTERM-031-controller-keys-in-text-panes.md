# UTERM-031: Controller Keys Outside Opted-In Panes

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-16

## Dependencies

- UTERM-024, for controller commands, keys, and the opt-in rule
- UTERM-013, for reserved keys, remaps, and the menu's key route

## Impacts

- UTERM-024 — "Which panes take a controller's keys": this extends a controller's keys to panes that do not opt in.

## Summary

Lets a controller's keys work in panes that take typed text, such as a terminal member or the source terminal. It is a
nice-to-have. The presenter steps from its slide pane, which opts in.

## Motivation

During a live demo, the presenter's user types in the terminal and then has to click back into the slide pane to step.
A key that worked from the terminal would save the click.

## Design Decisions (Settled)

### A key never takes typed input

Decision: in a pane that takes typed text, a controller key never takes a key that pane treats as input. Control and
Option keys are input to a terminal: Ctrl-C interrupts, and Ctrl-U and Ctrl-W edit the line. Plain keys are typed text.

Rationale: the design critic found that a controller binding Ctrl-C in a terminal member would take the interrupt and
learn line-editing keys.

## Design Decisions (Open)

### Which keys

- **Command keys only.** Command keys are never terminal input. Simplest safe rule.
- **Command keys, plus keys each applet type declares it never treats as input.**

### Menu placement and remaps

A Command key and a user's remap reach a command through a menu item today. Whether controller commands gain menu items
for this, against UTERM-024's palette-only decision.

### The source pane

Whether a key is live in the source terminal, which is not a group member.

### Nested groups

Only if keys are live outside members: which controller wins a key in a nested pane.

## Risks

- **A key takes input the user expects the pane to get** — likelihood: medium, impact: medium. Mitigation: the settled
  rule above, uniterm's reserved keys and remaps win, and UTERM-024's key indicator lists the key.

## Milestones

### M1: Keys outside opted-in panes

**Status:** NOT STARTED

- A controller's key invokes its command where this proposal makes it live
- No key reaches the controller as a terminal's typed input

## Decision Log

- 2026-11-15: Split from UTERM-024. The presenter binds no chord, so chords are not required.
- 2026-11-16: Narrowed to panes that do not opt in. UTERM-024 now takes any key, with or without modifiers, in opted-in
  panes, so chords there are no longer this proposal's.

## References

- ADR-04: uniterm owns key bindings
- ADR-09: control authority requires authenticated identity and explicit scope
