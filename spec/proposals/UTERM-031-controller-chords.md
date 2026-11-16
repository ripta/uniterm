# UTERM-031: Controller Chords

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, for controller commands and key ownership
- UTERM-013, for reserved keys, remaps, and the menu's key route

## Impacts

- UTERM-024 — "Palette only": a chord reaches a command only through a menu item today, so chords bring menu items back.

## Summary

Lets a controller bind chords, keys pressed with a modifier, to its commands. It is a nice-to-have. The presenter steps
with navigation keys, and binds no chord.

## Motivation

A chord works where navigation keys do not, such as in a terminal or browser member, or from the source terminal. A
presenter could step from the terminal during a live demo.

## Design Decisions (Settled)

### A chord never takes typed input

Decision: a controller chord never takes a key a terminal or text field treats as input. Control and Option keys are
input to a terminal: Ctrl-C interrupts, and Ctrl-U and Ctrl-W edit the line.

Rationale: the design critic found that a controller binding Ctrl-C in a terminal member would take the interrupt and
learn line-editing keys.

## Design Decisions (Open)

### Which modifiers

- **Command only.** Command keys are never terminal input. Simplest safe rule.
- **Command, or Control and Option outside text-input panes.** More keys, with the same opt-in rule as navigation keys.

### Menu placement and remaps

A chord and a user's remap reach a command only through a menu item. Where controller items go, and how a remap
matched by title is kept from reaching a controller item titled like another.

### The source pane

Whether a chord is live in the source terminal, which is not a group member.

### Nested groups

Only if chords are live outside members: which controller wins a chord in a nested pane.

## Risks

- **A chord takes a key the user expects elsewhere** — likelihood: medium, impact: medium. Mitigation: uniterm's reserved
  keys and remaps win, and the key indicator from UTERM-024 lists chords too.

## Milestones

### M1: Chords

**Status:** NOT STARTED

- A controller chord invokes its command where it is live
- A chord never reaches the controller as a terminal's typed input

## Decision Log

- 2026-11-15: Split from UTERM-024. The presenter binds no chord, so chords are not required.

## References

- ADR-04: uniterm owns key bindings
- ADR-09: control authority requires authenticated identity and explicit scope
