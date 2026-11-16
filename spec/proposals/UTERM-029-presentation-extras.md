# UTERM-029: Presentation Extras

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-025, for the presentation controller this extends
- UTERM-003, for `uniterm/send`
- UTERM-007, for the text viewer's PDF view
- UTERM-006 or UTERM-019, depending on which deck sources are chosen

## Impacts

None.

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

- **PDF.** The only way in today is `uniterm/send`, capped at 1 MiB, and exported decks with images often pass that. The
  viewer shows a PDF as one continuous column, so scrolling to a page can show its neighbors, depending on the pane's
  shape. A PDF deck needs a show-by-path route, such as UTERM-030's or UTERM-015's, and a single-page view.
- **An image folder.** A controller can send one image per step today through `uniterm/send`, within 1 MiB each.
  UTERM-006 M4 adds show-by-path and stepping, which is the better route.
- **HTML.** Stepping an HTML deck needs page JavaScript or trusted input from UTERM-019, not only its page events.

Which ones to build, and where each gets notes once UTERM-026 adds them.

### Go to Slide

Registry commands take no arguments today. Options for naming the slide:

- **A number typed in the palette**, which needs a new palette contract for an argument.
- **A form**, through UTERM-022's Questions applet.
- **A list of slide titles as commands**, which needs commands declared at runtime. UTERM-024 declares commands in
  the controller's file only, so this adds runtime declaration.

## Risks

- **Each new deck source is a format contract** — likelihood: medium, impact: medium. A PDF with sidecar notes is a new
  deck format. Mitigation: version it with UTERM-025's deck format.
- **An HTML deck is untrusted active content** — likelihood: medium, impact: medium. Mitigation: it runs in a controller
  tab under UTERM-019's rules.

## Milestones

### M1: More deck sources and Go to Slide

**Status:** NOT STARTED

- Each deck source settled under "Deck sources" shows and steps like a Markdown deck
- Go to Slide shows the named slide

## Decision Log

- 2026-11-15: Split from UTERM-025, which narrowed to the hot path.

## References

- None.
