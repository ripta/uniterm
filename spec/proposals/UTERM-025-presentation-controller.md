# UTERM-025: Presentation Controller

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, a required prerequisite: Next Slide and Previous Slide, bound to the arrow keys and Page Up and Page Down
- UTERM-030, a required prerequisite: slide text that fills the pane, and slide images
- UTERM-004, for controller runs, layout requests, groups, and remote control of the pane it opens
- UTERM-007, for the text viewer that shows the slides
- UTERM-021, for the `declare-permissions` form, including the `:fs-read` capability that reads the deck

## Impacts

- UTERM-026 — "Speaker notes" and "A second window": the presenter view and its notes build on this controller's deck
  format and commands.
- UTERM-029 — "Deck sources": other deck sources extend this controller's stepping.

## Summary

A presentation controller shows a Markdown deck, one slide at a time, in a text viewer pane. The user steps forward and
back with the arrow keys, Page Up and Page Down, a clicker, or the palette. It is a controller, not an applet.

Everything here is on the hot path. Speaker notes and the presenter view are UTERM-026. Other deck sources and Go to
Slide are UTERM-029.

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

Decision: the deck is one Markdown file. Slides may hold headings, lists, code, tables, and images.

Rationale: Markdown is the one deck source the text viewer shows today. PDF, image, and HTML decks are UTERM-029.

### Slides only

Decision: the presenter shows slides, in one pane. Speaker notes are UTERM-026.

Rationale: in one window the audience sees every pane, so a notes pane would show them the notes. Private notes need a
second window, which UTERM-026 settles.

### The deck stays in the user's files

Decision: the user names the deck when starting the presenter. The presenter reads it, and keeps no copy beyond its run.
Restoring a layout that held a presentation restores the pane inert, per ADR-03 and UTERM-004.

Rationale: the deck is the user's document. A copy would go stale when the user edits it, and would hold content the
user did not choose to store. `show-markdown` carries each slide without writing it to disk, unlike `uniterm/send`.

### Stepping

Decision: Next Slide and Previous Slide are the presenter's commands, declared through UTERM-024. Right Arrow, Down
Arrow, Page Down, and Space step forward. Left Arrow, Up Arrow, and Page Up step back. Each command is also in the
palette. Stepping past either end leaves the slide in place and posts a status message.

Rationale: these are the keys people step slides with, and the keys clickers send. A press past the end is a common
slip mid-talk, so the slide stays up rather than blanking.

## Design Decisions (Open)

### How it ships

- **A bundled controller package.** Signed, inside the app bundle, run through UTERM-004's trust flow. Users get it
  with uniterm. uniterm has never shipped a controller, so this settles signing, updates, and how users find it.
- **An example script in the repo.** A declared Janet file. Less to build, but it reaches only users with a checkout.
- **A separate repository.** Its own releases and signing. Keeps uniterm free of a built-in presenter.

### How it starts and ends

A declared `:fs-read` is granted only when the run also passes `--allow fs-read`, so a script presenter starts as
`uniterm run --allow fs-read presenter.janet deck.md`. That capability reads any file the user can. Options:

- **`:fs-read`**, as above.
- **The deck on stdin**, which needs no capability.
- **UTERM-030's path-reading power**, if it settles that the viewer opens the deck by path. The presenter then reads
  nothing itself.

Also: whether Ctrl-C in the source terminal is the only way to end it, or a Stop command joins Next and Previous.

### Deck format rules

- How slides split. A `---` line collides with a setext heading, where a line of text is followed by `---`, and with
  `---` inside a fenced code block.
- How a slide references images, which UTERM-030 resolves.
- Whether the format is versioned, if the presenter ships in the bundle.

### Layout

Where the slide pane sits beside the starting terminal, and its weight. Whether the starting terminal is in the
presenter's group decides whether a chord steps the deck from the terminal, per UTERM-024 "The source pane".

### Slide size

`show-markdown` caps a slide at 12 KiB, far more than a slide needs. What the presenter does with a slide over it:
refuse to start, or show an error slide in its place.

## Risks

- **UTERM-024's and UTERM-030's designs change what the presenter can do** — likelihood: medium, impact: medium.
  Mitigation: this proposal stays a draft until both are accepted, and its milestone follows theirs.
- **The presenter depends on UTERM-024's open "The source pane" for stepping from the terminal** — likelihood: medium,
  impact: low. During a live demo the user clicks back into the slide pane to step. Mitigation: settle "Layout" with
  UTERM-024's answer in hand.
- **A deck file is untrusted input** — likelihood: medium, impact: medium. Mitigation: the text viewer already renders
  untrusted Markdown. The presenter passes content through and adds no rendering of its own.
- **Shipping a controller in the bundle is a new contract** — likelihood: medium, impact: medium. Users would depend on
  its deck format. Mitigation: settle "How it ships" and "Deck format rules" before acceptance.

## Milestones

### M1: Present a Markdown deck

**Status:** NOT STARTED

- Starting the presenter on a Markdown deck opens a slide pane beside the starting terminal, in the slide style
- The arrow keys, Page Up and Page Down, Space, and the palette step the deck while the slide pane has focus
- A slide's images load
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
- 2026-11-15: Stepping uses the arrow keys and Page Up and Page Down, through UTERM-024's navigation keys. The user
  noted that people step slides with plain arrow keys.

## References

- ADR-03: restored state never runs a program
- ADR-09: control authority requires authenticated identity and explicit scope
