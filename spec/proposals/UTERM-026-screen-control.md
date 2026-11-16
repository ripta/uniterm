# UTERM-026: Screen Control

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-004, for groups, controller authority, and "Same window only"

## Impacts

- UTERM-004 — "Same window only": a presenter view needs a controller's panes in two windows.
- UTERM-025 — "Presenter view": this proposal is what makes it possible.

## Summary

Lets a pane fill its window, and lets a controller arrange its window for presenting: full screen, and a second window
on another display. This is a nice-to-have. The presentation controller works without it, in one ordinary window.

## Motivation

Two things a presenter wants are impossible today, for a script or by hand:

- Showing only the slide pane to an audience. uniterm has no way to zoom one pane to fill its window.
- A presenter view, with slides on the projector and notes on the laptop. That takes two windows, and a controller's
  panes live in one window.

Full screen and picking a display can be done by hand. A controller doing them is a convenience.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Pane zoom

Whether zoom is a user command that any pane has, a controller power, or both. How the other panes behave while one is
zoomed, per ADR-05's lifecycle events.

### Window and display control

Whether a controller may make its window full screen and move it to a display. Each needs its own power under ADR-09.
Pane control must not grant it.

### A second window

How a group spans two windows, against UTERM-004's "Same window only". Whether the second window belongs to the group,
and what the user sees and can revoke.

### Focus

Under ADR-12, a change the user did not choose never moves focus. Which of these changes count as chosen, such as one
made in response to a command the user invoked.

## Risks

- **Relaxing "Same window only" widens what a controller can reach** — likelihood: medium, impact: high. Mitigation:
  the second window holds only panes the controller opened, and revoking the controller covers both windows.

## Milestones

### M1: Pane zoom

**Status:** NOT STARTED

- A pane fills its window and returns, and the other panes keep their state

### M2: Presenter windows

**Status:** NOT STARTED

- A controller places its slide pane full screen on a second display and keeps its notes in the first window

## Decision Log

None yet.

## References

- ADR-05: applet lifecycle
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-12: unchosen changes never move focus or arm input
