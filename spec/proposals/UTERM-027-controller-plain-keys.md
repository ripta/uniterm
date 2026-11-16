# UTERM-027: Plain Keys for Controllers

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, for controller commands, chord shortcuts, and the key ownership this extends

## Impacts

- UTERM-025 — "Stepping": a clicker can step the deck. Not required by it.

## Summary

Lets a controller bind plain keys with no modifier, such as Page Down, the arrow keys, and Space, in its own panes. A
presentation clicker sends plain keys, so this is what makes a clicker work. It is a nice-to-have. The presenter works
with chords alone.

## Motivation

Presenters use clickers. A clicker sends Page Down, Page Up, the arrow keys, or Space. UTERM-024 allows only chords, so
a clicker needs a remap on every machine that presents.

## Design Decisions (Settled)

### Plain keys in the controller's own panes

Decision: a controller may bind plain keys. While a pane the controller owns has focus, the controller's key wins over
that pane's own handling of the key.

- uniterm's reserved keys and the user's remaps still win, as in UTERM-024.
- Each pane where a controller's plain keys are live shows that the controller is taking keys. The badge names the
  controller and lists its keys. The user can revoke the controller from there.

Rationale: the scope to the controller's own panes and the visible indicator bound the surprise of a pane that stops
scrolling or typing on Space.

## Design Decisions (Open)

### How plain keys reach the controller

Plain keys arrive through `keyDown`, not as key equivalents. Several views take them first, such as the terminal
surface, the REPL, and the image viewer. Options:

- Route plain keys through the window before the focused view, only while controller keys are live in that pane.
- Give each applet a hook that offers unmodified keys to the window first.

### The presenter's clicker keys

Which plain keys UTERM-025 binds once this lands.

## Risks

- **Plain-key capture confuses the user** — likelihood: medium, impact: medium. A pane stops scrolling or typing on
  Space, and the user does not know why. Mitigation: the indicator on each affected pane, the scope to the controller's
  own panes, and revoking from the badge.

## Milestones

### M1: Plain keys

**Status:** NOT STARTED

- A controller's plain key invokes its command while a pane the controller owns has focus, including a terminal pane
- In panes it does not own, the same key reaches the pane as before
- Each pane where controller keys are live shows the controller and its keys

## Decision Log

- 2026-11-15: Controllers may bind plain keys in their own panes, winning over the pane's own handling. The user chose
  this during UTERM-024's drafting. It moved here when UTERM-024 narrowed to what the presenter requires.

## References

- ADR-04: uniterm owns key bindings
