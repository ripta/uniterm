# UTERM-029: Presentation Extras

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-025, for the presentation controller this extends

## Impacts

- UTERM-006 — "M4: Control": an image-folder deck needs the image viewer's `show` and stepping commands.
- UTERM-019 — "Page events": an HTML deck needs browser automation.

## Summary

Deck sources beyond Markdown, and Go to Slide, for the presentation controller. None is required. UTERM-025 presents a
Markdown deck without them.

## Motivation

People already have decks in other forms: a PDF exported from another tool, a folder of images, an HTML deck. A long
talk also needs a way to jump to a slide during questions.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Deck sources

- **PDF**: one page per slide, notes from a sidecar file. Works with the text viewer's page scroll today.
- **An image folder**: waits on UTERM-006 M4.
- **HTML**: waits on UTERM-019.

Which ones to build, and the notes source for each.

### Go to Slide

Whether the presenter offers it, and how the user names the slide: a number typed in the palette, or a list of slide
titles.

## Risks

None identified: each item extends the presenter without changing UTERM-025's deck format or commands.

## Milestones

### M1: More deck sources and Go to Slide

**Status:** NOT STARTED

- Each deck source chosen under "Deck sources" shows and steps like a Markdown deck
- Go to Slide, if chosen, shows the named slide and its notes

## Decision Log

- 2026-11-15: Split from UTERM-025, which narrowed to the hot path.

## References

- None.
