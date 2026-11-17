# The text viewer's PDF body likely lets the user type into form fields

**Status:** open, not confirmed
**Estimate:** small; likely no design decision
**Found:** 2026-11-16, by the design critic reviewing UTERM-024

## Observed

UTERM-007 "Read-only" says the viewer views documents and does not edit them. PDFs render with PDFKit's `PDFView`
(`TextViewerView.swift:128`). By default, `PDFView` lets the user click into an AcroForm text field and type. Nothing in
`TextViewerApplet` turns that off. A search for annotation, widget, or read-only handling there finds nothing.

Not confirmed: no one has opened a form PDF in the viewer and typed into a field.

## Why it matters

Typed form input is an edit, against UTERM-007. It also matters to UTERM-024, which lets a controller's keys reach only
pane bodies that never take typed text. UTERM-024 keeps the PDF body out for this reason. If a later change opted it in,
a controller could read what the user types into a field.

## Repro

Open a PDF with a fillable text field in a text viewer pane. Click the field and type.

- Expected, per UTERM-007 "Read-only": the field takes no text.
- Suspected: the text appears in the field.

## Fix

If it reproduces: make widget annotations read-only when a document loads, or stop the view from starting a field
editor. Write the failing test first, with a synthetic form PDF.
