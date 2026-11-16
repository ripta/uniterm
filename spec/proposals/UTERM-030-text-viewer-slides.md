# UTERM-030: Text Viewer Slides

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-16

## Dependencies

- UTERM-007, for the text viewer, its Markdown page, and its remote schema
- UTERM-004, for remote control of a viewer pane
- UTERM-015, for the path-reading power and its checks, built in its M4
- UTERM-032, for the input file's folder the user grants when starting the controller

## Impacts

- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Slides need text
  that fills the pane, and images.
- UTERM-024 — "Which panes take a controller's keys": the text viewer's page opts in to controller keys. The arrow keys step
  slides, so a slide's overflow rule cannot rely on scrolling by keyboard.
- UTERM-007 — "Control levels": the viewer's remote schema gains a minor version.

## Summary

Two text viewer changes a slide deck needs. A slide style lays Markdown out to fill the pane, instead of a 15px
document column. Images in a slide load from the deck's folder, instead of showing alt text.

## Motivation

The text viewer is built to read documents. Its stylesheet sets body text at 15px and caps the column at 860px, centered
(`viewer.css`). Headings are relative to that, so a top-level heading is 30px. On a projector that is a README page in
the middle of the screen. A deck cannot override it, since the page's content security policy blocks inline styles and
a deck runs no script. The viewer's own script runs in a separate content world, so the host can restyle the page.

Images fail for a different reason. A controller sends each slide with `show-markdown`. Inline Markdown has no file and
so no folder, and the page shows each image's alt text.

## Design Decisions (Settled)

### Two features in the viewer, not the presenter

Decision: the slide style and slide images are text viewer features, reached through its remote schema. The viewer
shows one slide's Markdown at a time. It does not split decks.

Rationale: the presenter passes content through and adds no rendering of its own, per UTERM-025. Splitting a deck is
the presenter's job, under UTERM-025's "Deck format rules". Other controllers that show Markdown gain the same
features.

### The Markdown page opts in

Decision: the text viewer's Markdown body opts in to controller keys, under UTERM-024 "Which panes take a controller's
keys". Its PDF and text bodies do not.

Rationale: the Markdown page takes no typed text. Its sanitizer allows no `input`, `textarea`, `select`, or
`contenteditable`, and the page runs no script. A PDF can hold form fields, and the find bar and contents sidebar take
their own keys, so none of those opt in.

### A slide style, not a zoom

Decision: the viewer gains a named slide style that a controller sets on its pane. The style sizes type to the pane and
drops the column cap. There is no arbitrary zoom or scale factor. The viewer does not save the style with the layout.
Restoring a presentation is the controller's job: a restored pane is inert, and a presenter that runs again sets the
style again.

Rationale: a slide needs type laid out for a slide, sized from the pane, with headings and lists in proportion. A zoom
factor scales the document style, so it keeps the column and leaves the controller guessing a number for each display.

### Slide images

Decision: `show-markdown` takes a base folder for a slide's relative images. The folder must lie inside the input
file's folder the user granted, under UTERM-032. The viewer reads each image under UTERM-015 M4's checks.

- Each image path is confined to the granted folder. A `..` or a symlink that leaves it is refused. This is stricter
  than the volume rule for documents the user opens, per UTERM-007's 2026-11-08 ADR candidate.
- A missing, refused, or out-of-scope image shows the same alt text, so the outcome tells the controller nothing about
  what exists.
- Remote, root-relative, and data-URI images stay refused, as for any Markdown the viewer shows.
- Once the grant ends, the viewer reads no further image. A slide that renders again, such as after WebKit's content
  process restarts or an undo restores it, shows alt text.

Rationale: the user chose a folder granted at run time, with the controller holding no file access, over sending image
bytes with each slide. The folder confinement follows UTERM-015's rule that a controller never borrows uniterm's macOS
privacy grants. The bug "Images in Markdown a script sends resolve anywhere on the volume" shows what the volume rule
allows for content a program supplied.

### Version skew

Decision: the slide style and the base folder argument are a minor version of the viewer's remote schema. A controller
written for the new minor that reaches an older viewer is refused before any effect, under the schema's major and minor
rule. An older controller reaching a newer viewer gets the document style and no images, as today.

## Design Decisions (Open)

### The slide style's rules

How type sizes from the pane, such as from its height or its width, and the bounds on it. How a slide that overflows
the pane behaves. Shrinking to fit works with the keys, since the arrow keys step slides and cannot scroll. Whether the
user can switch a pane's style.

## Risks

- **A schema minor version is a published contract** — likelihood: high, impact: low. Mitigation: the remote schema's
  major and minor rule already covers new commands and arguments.
- **Images widen what a controller can make the viewer read** — likelihood: medium, impact: medium. Mitigation: reads are
  confined to the folder the user granted for that run, under UTERM-015's checks.

## Milestones

### M1: Slide style

**Status:** NOT STARTED

- The Markdown body delivers controller keys, and the PDF and text bodies do not
- A controller sets the slide style on a viewer pane, and a heading and a bullet list fill a projector-sized pane
- A user-opened document keeps the document style

### M2: Slide images

**Status:** NOT STARTED

- A slide's relative image loads from a base folder inside the granted folder
- A base folder outside the granted folder is refused before anything is read
- An image reached by `..` or an absolute symlink outside the granted folder shows alt text, the same as a missing image
- Remote, root-relative, and data-URI images stay refused
- Builds on UTERM-032 M1's grant
- After the grant ends, a slide that renders again reads no image and shows alt text

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose readable projected text and slide images as
  required, after the design critic found the 15px column and the alt-text images.
- 2026-11-15: A named slide style, with no arbitrary zoom. The user chose it.
- 2026-11-15: Slide images load from a base folder inside the folder granted at run time. The user chose this. The
  option where the viewer opens the deck file by path was dropped, since it would put deck splitting in the viewer.
- 2026-11-16: the viewer does not save the slide style. The user's reason: the controller is in charge, so restoring
  is the controller's job. A restored pane is inert, and the controller sets the style again when it runs.
- 2026-11-16 (agent): the Markdown body opts in to controller keys, and the PDF and text bodies do not. UTERM-024 puts
  the opt-in in each applet's proposal.

## References

- ADR-06: layout file versioning
- ADR-09: control authority requires authenticated identity and explicit scope
