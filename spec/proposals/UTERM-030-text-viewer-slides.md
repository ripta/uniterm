# UTERM-030: Text Viewer Slides

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-007, for the text viewer, its Markdown page, and its remote schema
- UTERM-004, for remote control of a viewer pane
- UTERM-015, for the path-reading power that lets a controller have the viewer read a deck's folder

## Impacts

- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Slides need text
  that fills the pane, and images.
- UTERM-007 — "Control levels": the viewer's remote schema gains a minor version.

## Summary

Two text viewer changes a slide deck needs. A slide style scales Markdown to fill the pane, instead of a 15px document
column. Images in a slide load from the deck's folder, instead of showing alt text.

## Motivation

The text viewer is built to read documents. Its stylesheet sets body text at 15px and caps the column at 860px, centered
(`viewer.css`). Headings are relative to that, so a top-level heading is 30px. On a projector that is a README page in
the middle of the screen. A deck cannot override it, since the page's content security policy blocks inline styles and
the page runs no script.

Images fail for a different reason. A controller sends each slide with `show-markdown`. Inline Markdown has no file and
so no folder, and the page shows each image's alt text. A Markdown file the user opens resolves images beside the file.

## Design Decisions (Settled)

### Two features in the viewer, not the presenter

Decision: the slide style and image loading are text viewer features, reached through its remote schema.

Rationale: the presenter passes content through and adds no rendering of its own, per UTERM-025. Other controllers that
show Markdown gain the same features.

### A slide style, not a zoom

Decision: the viewer gains a named slide style that a controller sets on its pane. The style sizes type to the pane and
drops the column cap. There is no arbitrary zoom or scale factor.

Rationale: a slide needs type laid out for a slide, sized from the pane, with headings and lists in proportion. A zoom
factor scales the document style, so it keeps the column and leaves the controller guessing a number for each display.

## Design Decisions (Open)

### The slide style's rules

How type sizes from the pane, such as from its height or its width, and the bounds on it. How a slide that overflows
the pane behaves: shrink to fit, or scroll. Whether the user can switch a pane's style, and whether it survives a
restore.

### How a slide finds its images

- **The viewer opens the deck file by path**, under UTERM-015's path-reading power, and shows one slide of it at a
  time. Images resolve beside the file, as they do for a file the user opens.
- **`show-markdown` takes a base folder**, checked against the controller's read scope. The controller still splits the
  deck.

Either way, an image outside the scope is refused with UTERM-015's single error, and no path from outside leaks back.

## Risks

- **A schema minor version is a published contract** — likelihood: high, impact: low. Mitigation: the remote schema's
  major and minor rule already covers new commands and arguments.
- **Images widen what a controller can make the viewer read** — likelihood: medium, impact: medium. Mitigation: reads go
  through UTERM-015's scoped power, with its symlink and canonicalization rules.

## Milestones

### M1: Slide style

**Status:** NOT STARTED

- A controller sets the slide style on a viewer pane, and a heading and a bullet list fill a projector-sized pane
- A user-opened document keeps the document style

### M2: Slide images

**Status:** NOT STARTED

- A slide's relative image loads from the deck's folder
- An image outside the controller's read scope is refused with the same error as a missing one

## Decision Log

- 2026-11-15: Filed as a required prerequisite of UTERM-025. The user chose readable projected text and slide images as
  required, after the design critic found the 15px column and the alt-text images.
- 2026-11-15: A named slide style, with no arbitrary zoom. The user chose it.

## References

- ADR-09: control authority requires authenticated identity and explicit scope
