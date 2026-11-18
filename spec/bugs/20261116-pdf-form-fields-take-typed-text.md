# The text viewer's PDF body likely lets the user type into form fields

**Status:** open
**Estimate:** small; no open design decisions. Set `isReadOnly` on every widget annotation in `show(pdf:)`, a trivial
choice because it follows the fix this bug already records and it keeps the viewer read-only per UTERM-007.
**Found:** 2026-11-16, by the design critic reviewing UTERM-024

## Observed

UTERM-007 "Read-only" says the viewer views documents and does not edit them. PDFs render with PDFKit's `PDFView`
(`TextViewerView.swift:128`). By default, `PDFView` lets the user click into an AcroForm text field and type. Nothing in
`TextViewerApplet` turns that off. A search for annotation, widget, or read-only handling there finds nothing.

Confirmed 2026-11-18 by a throwaway test, since deleted. It loaded a PDF with one text widget into a
`TextViewerApplet`, put the view in a window, and sent a click on the field followed by `insertText("hello")`. The
field took the text and `widgetStringValue` read `hello`. With `isReadOnly = true` set on the widget first, the same
click and input left `widgetStringValue` nil. The test used a synthetic PDF made with PDFKit and not the clipboard.

## Why it matters

Typed form input is an edit, against UTERM-007. It also matters to UTERM-024, which lets a controller's keys reach only
pane bodies that never take typed text. UTERM-024 keeps the PDF body out for this reason. If a later change opted it in,
a controller could read what the user types into a field.

## Repro

Open a PDF with a fillable text field in a text viewer pane. Click the field and type.

- Expected, per UTERM-007 "Read-only": the field takes no text.
- Suspected: the text appears in the field.

## Fix

It reproduces. Make widget annotations read-only when a document loads, or stop the view from starting a field
editor. Write the failing test first, with a synthetic form PDF.
