# UTERM-025: Presentation Controller

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, the required prerequisite: the commands and chord shortcuts that step through a deck
- UTERM-004, for controller runs, layout requests, groups, and remote control of the panes it opens
- UTERM-007, for the text viewer's `show-markdown` command that shows slides and notes
- UTERM-021, for the `declare-permissions` form, including the `:fs-read` capability that reads the deck

## Impacts

- UTERM-026 — screen control turns this controller's window into a presenter view. Not required.
- UTERM-027 — plain keys let a clicker step the deck. Not required.
- UTERM-029 — more deck sources and Go to Slide. Not required.

## Summary

A presentation controller shows a Markdown deck with speaker notes, using the text viewer. It lays out a slide pane and
a notes pane, shows one slide at a time, and steps forward and back on the user's command from the palette or a chord
shortcut. It is a controller, not an applet.

Everything here is on the hot path. What is nice to have lives in UTERM-026, UTERM-027, and UTERM-029.

## Motivation

Presenting from a terminal app is a real workflow: a talk about a tool, with the tool live in the next pane. Today that
means a separate presentation app and switching windows mid-talk.

uniterm already has the pieces to show content. The text viewer renders Markdown, and a controller can lay out panes
and command them. A presenter built from those pieces needs no new applet. It also proves the controller model on
something people use, rather than on test fixtures. And it gives anyone writing a controller a working starting point.
The repo has no sample controller today, and no `.janet` file outside the test fixtures.

`spec/ideas.md` "Sample presentation controller" records the starting survey.

## Design Decisions (Settled)

### A controller, not an applet

Decision: the presenter is a controller that drives existing applets. It adds no applet type.

Rationale: the applets already show the content. What a presenter adds is sequence and input, which is controller work.
Any gap it finds belongs to the controller model, where every other controller gains from the fix.

### A Markdown deck

Decision: the deck is one Markdown file. Slides are split on `---`. Each slide's notes sit in a marked block inside it.
The exact notes syntax is open. See "Notes syntax".

Rationale: Markdown is the one deck source that works with today's text viewer and carries its notes in the same file.
PDF, image, and HTML decks are UTERM-029.

### The deck stays in the user's files

Decision: the user names the deck when starting the presenter. The presenter reads it with `:fs-read`, and keeps no copy
beyond its run. Restoring a layout that held a presentation restores the panes inert, per ADR-03 and UTERM-004.

### Stepping

Decision: Next Slide and Previous Slide are the presenter's commands, declared through UTERM-024 with chord shortcuts.
Each one updates the slide pane and the notes pane together. Stepping past either end does nothing.

## Design Decisions (Open)

### How it ships

- **A bundled controller package.** Signed, inside the app bundle, run through UTERM-004's trust flow. Users get it
  with uniterm. uniterm has never shipped a controller, so this settles signing, updates, and how users find it.
- **An example script in the repo.** A declared Janet file. Less to build, but it reaches only users with a checkout.
- **A separate repository.** Its own releases and signing. Keeps uniterm free of a built-in presenter.

### Notes syntax

How a slide marks its notes: an HTML comment, a fenced block with a `notes` tag, or a heading such as `Notes:`.

### Layout

How the slide and notes panes sit beside the terminal that started the presenter, and their weights.

### Default shortcuts

Which chords step the deck, checked against uniterm's reserved keys.

### Slide size

Inline Markdown has a size cap. Each slide is sent alone, so a slide must fit under it. What the presenter does with a
slide that does not: refuse to start, or show an error slide in its place.

## Risks

- **UTERM-024's design changes what the presenter can do** — likelihood: medium, impact: medium. Mitigation: this
  proposal stays a draft until UTERM-024 is accepted, and its milestones follow UTERM-024's.
- **A deck file is untrusted input** — likelihood: medium, impact: medium. Mitigation: the text viewer already renders
  untrusted Markdown. The presenter passes content through and adds no rendering of its own.
- **Shipping a controller in the bundle is a new contract** — likelihood: medium, impact: medium. Users would depend on
  its deck format. Mitigation: settle "How it ships" before acceptance, and version the deck format if it is bundled.

## Milestones

### M1: Present a Markdown deck

**Status:** NOT STARTED

- Starting the presenter on a Markdown deck lays out a slide pane and a notes pane beside the starting terminal
- Next Slide and Previous Slide, from the palette and from their chords, update both panes
- Stepping past either end does nothing
- Ending the presenter removes its commands and keys, and leaves the panes showing the last slide
- A slide over the size cap is handled as "Slide size" settles
- A UI test runs a synthetic deck in the real app and captures each step on screen

## Decision Log

- 2026-11-15: The presenter is a controller over existing applets, not an applet.
- 2026-11-15: Narrowed to the hot path. Markdown is the one deck source, since it works today and carries its notes.
  PDF, image, and HTML decks and Go to Slide moved to UTERM-029. Clicker keys moved to UTERM-027. The presenter view
  stays in UTERM-026. The previous text had a second milestone for more deck sources.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
