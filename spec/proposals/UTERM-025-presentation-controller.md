# UTERM-025: Presentation Controller

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, a required prerequisite: Next Slide and Previous Slide, bound to the arrow keys and Page Up and Page Down
- UTERM-030, a required prerequisite: slide text that fills the pane, and slide images
- UTERM-032, a required prerequisite: the deck's folder, granted when the presenter starts
- UTERM-015 M4, a required prerequisite through UTERM-030 and UTERM-032: the path-reading power
- UTERM-003, for `uniterm run` and the Janet module
- UTERM-004, for controller runs, layout requests, groups, and remote control of the pane it opens
- UTERM-007, for the text viewer that shows the slides
- UTERM-021, for the `declare-permissions` form

## Impacts

- UTERM-026 — "Speaker notes" and "A second window": the presenter view and its notes build on this controller's deck
  format and commands.
- UTERM-029 — "Deck sources": other deck sources extend this controller's stepping.

## Summary

A presentation controller shows a Markdown deck, one slide at a time, in a text viewer pane beside the terminal that
started it. The user steps forward and back with the arrow keys, Page Up and Page Down, a clicker, or the palette. It is
a controller, not an applet.

Everything here is on the hot path. Speaker notes, pane zoom, and the presenter view are UTERM-026. Other deck sources
and Go to Slide are UTERM-029.

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
Any gap it finds belongs to the controller model, where every other controller gains from the fix. A slide mode built
into the viewer would need fewer prerequisites, but would prove nothing about controllers.

### A Markdown deck

Decision: the deck is one Markdown file. Slides may hold headings, lists, code, tables, and images.

Rationale: Markdown is the one deck source the text viewer shows today. PDF, image, and HTML decks are UTERM-029.

### Slides only, beside the terminal

Decision: the presenter shows slides in one pane, beside the terminal that started it, in a normal window. Speaker notes
and a slide that fills the screen are UTERM-026.

Rationale: in one window the audience sees every pane, so a notes pane would show them the notes. A slide beside the
terminal suits a live demo, and the user chose it as enough for the hot path.

### How it starts

Decision: the user starts the presenter on a deck. The deck's folder is granted for that run under UTERM-032, and the
deck's text arrives on stdin. The presenter holds no file access of its own.

Rationale: the user chose the least access that works. Images load from the granted folder through UTERM-030.

### The deck stays in the user's files

Decision: the presenter keeps no copy of the deck beyond its run. Restoring a layout that held a presentation restores
the pane inert, per ADR-03 and UTERM-004.

Rationale: the deck is the user's document. A copy would go stale when the user edits it, and would hold content the
user did not choose to store. `show-markdown` carries each slide without writing it to disk, unlike `uniterm/send`.

### Stepping

Decision: Next Slide and Previous Slide are the presenter's commands, declared through UTERM-024. Right Arrow, Down
Arrow, and Page Down step forward. Left Arrow, Up Arrow, and Page Up step back. Each command is also in the palette.
Stepping past either end leaves the slide in place and posts a status message.

Rationale: these are the keys people step slides with, and the keys clickers send. A press past the end is a common
slip mid-talk, so the slide stays up rather than blanking.

## Design Decisions (Open)

### How it ships

- **A bundled controller package.** Signed, inside the app bundle, run through UTERM-004's trust flow. Users get it
  with uniterm. uniterm has never shipped a controller, so this settles signing, updates, and how users find it.
- **An example script in the repo.** A declared Janet file. Less to build, but it reaches only users with a checkout.
- **A separate repository.** Its own releases and signing. Keeps uniterm free of a built-in presenter.

### How it ends

Whether Ctrl-C in the source terminal is the only way to end it, or a Stop command joins Next and Previous.

### Deck format rules

- How slides split. A `---` line collides with a setext heading, where a line of text is followed by `---`, and with
  `---` inside a fenced code block.
- How a slide references images, relative to the deck file.
- Whether the format is versioned, if the presenter ships in the bundle.

### Layout

Where the slide pane sits beside the starting terminal, and its weight.

### Slide size

`show-markdown` caps a slide at 12 KiB, far more than a slide needs. What the presenter does with a slide over it:
refuse to start, or show an error slide in its place.

## Risks

- **The prerequisites' designs change what the presenter can do** — likelihood: medium, impact: medium. Mitigation:
  this proposal stays a draft until UTERM-024, UTERM-030, and UTERM-032 are accepted.
- **UTERM-015 M4 is unbuilt and large** — likelihood: high, impact: medium. Slide images wait on it, and it waits on
  UTERM-004 M6. Mitigation: it is already queued. The presenter's milestone follows it.
- **Stepping needs focus in the slide pane** — likelihood: medium, impact: low. During a live demo the user clicks back
  into the slide pane to step. Accepted: chords from the terminal are UTERM-031.
- **A deck file is untrusted input** — likelihood: medium, impact: medium. Mitigation: the text viewer already renders
  untrusted Markdown. The presenter passes content through and adds no rendering of its own.
- **Shipping a controller in the bundle is a new contract** — likelihood: medium, impact: medium. Users would depend on
  its deck format. Mitigation: settle "How it ships" and "Deck format rules" before acceptance.

## Milestones

### M1: Present a Markdown deck

**Status:** NOT STARTED

- Starting the presenter on a Markdown deck opens a slide pane beside the starting terminal, in the slide style
- The arrow keys, Page Up and Page Down, and the palette step the deck while the slide pane has focus
- A slide's images load from the deck's folder
- Stepping past either end leaves the slide in place and posts a status message
- Ending the presenter removes its commands and keys, and leaves the pane showing the last slide
- A slide over the size cap is handled as "Slide size" settles
- A UI test runs a synthetic deck in the real app and captures each step on screen

## Decision Log

- 2026-11-15: The presenter is a controller over existing applets, not an applet.
- 2026-11-15: Markdown is the one deck source on the hot path. The user confirmed it.
- 2026-11-15: Speaker notes moved off the hot path to UTERM-026. The user chose this after the design critic found that
  one window shows the audience every pane.
- 2026-11-15: Readable projected text and slide images are required. The user chose both, and they became UTERM-030.
- 2026-11-15: Stepping uses the arrow keys and Page Up and Page Down. The user noted that people step slides with plain
  arrow keys. Space was dropped from the keys, since it types text.
- 2026-11-15: The deck's folder is granted at run time, and the deck arrives on stdin. The user chose this, and it
  became UTERM-032.
- 2026-11-15: A slide pane beside the terminal is enough for the hot path. The user chose this. Pane zoom stays in
  UTERM-026.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
