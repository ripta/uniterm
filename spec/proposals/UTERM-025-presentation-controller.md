# UTERM-025: Presentation Controller

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, for the commands, shortcuts, and events that let the user step through a deck
- UTERM-004, for controller runs, layout requests, groups, and remote control of the panes it opens
- UTERM-007, for the text viewer's `show-markdown` and `scroll` commands that show slides and notes
- UTERM-021, for the `declare-permissions` form the controller's script file carries

## Impacts

- UTERM-026 — "Summary": screen control is what turns this controller's window into a full presenter view, with only
  the slide on the audience's display.
- UTERM-006 — "M4: Control": an image-folder deck needs the image viewer's `show` and stepping commands.
- UTERM-019 — "Page events": an HTML deck needs browser automation.

## Summary

A presentation controller shows a deck of slides with speaker notes, using uniterm's existing applets. It lays out a
slide pane and a notes pane, shows one slide at a time, and steps forward and back on the user's command, from the
palette, a shortcut, or a clicker. It is a controller, not an applet. It drives the text viewer, and later the image
viewer and the browser, through their command schemas.

## Motivation

Presenting from a terminal app is a real workflow: a talk about a tool, with the tool live in the next pane. Today that
means a separate presentation app and switching windows mid-talk.

uniterm already has the pieces to show content. The text viewer renders Markdown and pages through PDFs. A controller
can lay out panes and command them. A presenter built from those pieces needs no new applet. It also proves the
controller model on something people use, rather than on test fixtures.

## Design Decisions (Settled)

### A controller, not an applet

Decision: the presenter is a controller that drives existing applets. It adds no applet type.

Rationale: the applets already show the content. What a presenter adds is sequence and input, which is controller work.
Building it as a controller keeps it replaceable, and any gap it finds belongs to the controller model, where every
other controller gains from the fix.

### The deck stays in the user's files

Decision: the deck is a file or folder the user names when starting the presenter. The presenter reads it, and keeps no
copy beyond its run. Restoring a layout that held a presentation restores the panes inert, per ADR-03 and UTERM-004.

### Stepping

Decision: Next Slide and Previous Slide are the presenter's commands, declared through UTERM-024. Each one updates the
slide pane and the notes pane together. Stepping past either end does nothing.

## Design Decisions (Open)

### How it ships

- **A bundled controller package.** Signed, inside the app bundle, run through UTERM-004's trust flow. Users get it
  with uniterm. uniterm has never shipped a controller, so this settles signing, updates, and how users find it.
- **An example script in the repo.** A declared Janet file. Less to build, but it reaches only users with a checkout.
- **A separate repository.** Its own releases and signing. Keeps uniterm free of a built-in presenter.

### Deck sources

- **Markdown**: one file, slides split on `---`, notes in a marked block. Works with `show-markdown` today.
- **PDF**: one page per slide, notes from a sidecar file. Works with the text viewer's page scroll today.
- **An image folder**: waits on UTERM-006 M4.
- **HTML**: waits on UTERM-019.

Which ones the first version supports, and the notes syntax for each.

### Layout

How the slide and notes panes sit beside the terminal that started the presenter, their weights, and whether a third
pane shows the next slide or a timer.

### Clicker keys

Which plain keys the presenter binds by default: Page Down and Page Up, the arrow keys, and Space are common clicker
outputs. UTERM-024 settles that a controller may bind plain keys in its own panes. This proposal picks the set.

### Presenter view

Slides on one display and notes on another needs UTERM-026. Whether the first version waits for it, or ships the
single-window layout first.

## Risks

- **UTERM-024's design changes what the presenter can do** — likelihood: medium, impact: medium. Mitigation: this
  proposal stays a draft until UTERM-024 is accepted, and its milestones follow UTERM-024's.
- **A deck file is untrusted input** — likelihood: medium, impact: medium. A deck from someone else could hold content
  that misleads in the notes or slides. Mitigation: the text viewer already renders untrusted Markdown and PDF. The
  presenter passes content through and adds no rendering of its own.
- **Shipping a controller in the bundle is a new contract** — likelihood: medium, impact: medium. Users would depend on
  its deck format. Mitigation: settle "How it ships" before acceptance, and version the deck format if it is bundled.

## Milestones

### M1: Markdown deck in one window

**Status:** NOT STARTED

- Starting the presenter on a Markdown deck lays out a slide pane and a notes pane beside the starting terminal
- Next Slide and Previous Slide from the palette update both panes
- A clicker's keys step the deck while a presenter pane has focus
- Ending the presenter removes its commands and keys, and leaves the panes showing the last slide
- A UI test runs a synthetic deck in the real app and captures each step on screen

### M2: More deck sources

**Status:** NOT STARTED

- Each deck source chosen under "Deck sources" beyond Markdown shows and steps like M1

## Decision Log

- 2026-11-15: The presenter is a controller over existing applets, not an applet.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
