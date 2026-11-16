# UTERM-026: Presenter View and Screen Control

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-001, for the pane tree and windows
- UTERM-002 and UTERM-013, for a pane zoom command and its key
- UTERM-004, for groups, controller authority, saved layouts, and "Same window only"
- UTERM-021, for declaring the new powers
- UTERM-024, for controller commands, which a group across two windows must keep working
- UTERM-025, for the presentation controller and its deck format

## Impacts

- UTERM-004 — "Same window only": a presenter view needs a controller's panes in two windows. UTERM-004 is implemented,
  so this would supersede that rule in part.
- UTERM-024 — "Powers and lifecycle": its cleanup when "the window closes" assumes a group in one window.
- UTERM-025 — "Slides only": speaker notes return through this proposal.

## Summary

Speaker notes the audience cannot see, and the screen control a presenter view needs: a pane that fills its window,
full screen, and a second window on another display. This is a nice-to-have. The presentation controller works without
it, showing slides only.

## Motivation

In one window, the audience sees every pane. A presenter with notes needs the slides on the projector and the notes on
the laptop, which takes two windows. Showing only the slide pane also needs a pane that fills its window. uniterm has
neither today, for a script or by hand.

`spec/ideas.md` "Share a pane or tab in a screen share" wants a pop-out window that holds one pane, for a video call. It
is the same mechanism, so one design should serve both.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Speaker notes

How a slide marks its notes in UTERM-025's deck format: an HTML comment, a fenced block with a `notes` tag, or a heading
such as `Notes:`. Where the notes pane lives: the second window.

### Pane zoom

Whether zoom is a user command that every pane has, a controller power, or both. How the other panes behave while one is
zoomed, per ADR-05's lifecycle events. Where keys go when zoom hides the pane that had focus, per ADR-12.

### A second window

- **A user-level Pop Out Pane command** that a controller may request. It also serves the screen-share idea.
- **A controller power to open a window** that holds panes it opens fresh.

Also: whether a pane moves to the new window or opens fresh there, since moving a live pane carries the unknowns of
the "Move tabs between panes" spike in `spec/ideas.md`. And how a group spans two windows.

### Authority across windows

ADR-09 limits a grant to its authorized window. A group across two windows needs a superseding or amending ADR, and a
superseding of UTERM-004's "Same window only" in part. Also: what the user sees and can revoke in each window.

### Window and display control

Whether a controller may make its window full screen and move it to a display. Each needs its own power under ADR-09,
with a permission kind and its declaration spelling under UTERM-021. Pane control must not grant it.

### Saving and restoring

Whether zoom state and a two-window group are saved with a layout, under ADR-06's versioning and ADR-03.

### Focus

Under ADR-12, a change the user did not choose never moves focus. Which of these changes count as chosen, such as one
made in response to a command the user invoked.

## Risks

- **Widening a grant past one window widens what a controller can reach** — likelihood: medium, impact: high.
  Mitigation: settle "Authority across windows" with an ADR before acceptance. The second window holds only panes of the
  controller's group, and revoking covers both windows.
- **The macOS "Displays have separate Spaces" setting** — likelihood: medium, impact: medium. When it is off, a full
  screen window on one display blanks the other, and the notes window is lost. Mitigation: detect the setting, and fall
  back to a window that is not full screen.

## Milestones

### M1: Pane zoom

**Status:** NOT STARTED

- A pane fills its window and returns, and the other panes keep their state

### M2: Presenter view

**Status:** NOT STARTED

- The presenter shows its slide on one display and the speaker notes in a second window on the other

## Decision Log

- 2026-11-15: Filed as a nice-to-have split from UTERM-024.
- 2026-11-15: Speaker notes moved here from UTERM-025. The user chose to keep notes off the presenter's hot path.

## References

- ADR-03: restored state never runs a program
- ADR-05: applet lifecycle
- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-12: unchosen changes never move focus or arm input
