import AppKit
import PDFKit
import XCTest

@testable import TextViewerApplet

/// Proves that a PDF's form fields do not take input once the document is loaded for the viewer.
/// The viewer is read-only, so typed text, toggles, and choices are edits it must refuse. Push
/// buttons take no typed text and stay unlocked, so their actions keep working. The tests use a
/// synthetic form PDF. A click on a choice widget opens a menu that a test cannot drive, so that
/// widget is proved only by its read-only flag.
@MainActor
final class PDFFormFieldTests: XCTestCase {
  private func widget(
    _ type: PDFAnnotationWidgetSubtype, _ name: String, at origin: CGPoint
  ) -> PDFAnnotation {
    let annotation = PDFAnnotation(
      bounds: CGRect(origin: origin, size: CGSize(width: 120, height: 24)), forType: .widget,
      withProperties: nil)

    annotation.widgetFieldType = type
    annotation.fieldName = name
    annotation.isReadOnly = false

    return annotation
  }

  private func formPDF() throws -> Data {
    let document = PDFDocument()
    let page = PDFPage()

    page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 400), for: .mediaBox)
    document.insert(page, at: 0)

    let text = widget(.text, "text", at: CGPoint(x: 20, y: 340))
    let check = widget(.button, "check", at: CGPoint(x: 20, y: 300))
    check.widgetControlType = .checkBoxControl
    let choice = widget(.choice, "choice", at: CGPoint(x: 20, y: 260))
    choice.widgetStringValue = "a"
    choice.choices = ["a", "b"]
    let push = widget(.button, "push", at: CGPoint(x: 20, y: 220))
    push.widgetControlType = .pushButtonControl

    for annotation in [text, check, choice, push] { page.addAnnotation(annotation) }

    return try XCTUnwrap(document.dataRepresentation())
  }

  private func loaded() throws -> [String: PDFAnnotation] {
    let result = PDFLoading.document(from: try formPDF())
    let document = try result.get().document
    let page = try XCTUnwrap(document.page(at: 0))
    var byName: [String: PDFAnnotation] = [:]

    for annotation in page.annotations {
      if let name = annotation.fieldName { byName[name] = annotation }
    }

    return byName
  }

  /// Catches a loader that leaves text, checkbox, and choice widgets editable, and one that locks
  /// push buttons.
  func testValueWidgetsAreReadOnlyAndPushButtonsAreNot() throws {
    let widgets = try loaded()

    XCTAssertEqual(widgets.count, 4)
    XCTAssertEqual(widgets["text"]?.isReadOnly, true)
    XCTAssertEqual(widgets["check"]?.isReadOnly, true)
    XCTAssertEqual(widgets["choice"]?.isReadOnly, true)
    XCTAssertEqual(widgets["push"]?.isReadOnly, false)
  }

  private func shown(_ window: NSWindow) async throws -> (TextViewerApplet, PDFView) {
    let scratch = try Scratch(self)
    let path = try scratch.write("form.pdf", try formPDF())
    let applet = Harness.applet(startDirectory: scratch.url.path)

    window.contentView = applet.content
    try applet.replaceSource(with: path, startDirectory: scratch.url.path)
    _ = await Harness.settled(applet)
    applet.content.pdfView.layoutSubtreeIfNeeded()

    return (applet, applet.content.pdfView)
  }

  private func click(_ field: PDFAnnotation, in view: PDFView, window: NSWindow) async throws {
    let page = try XCTUnwrap(field.page)
    let point = view.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), from: page)
    let location = view.convert(point, to: nil)

    func event(_ type: NSEvent.EventType) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    window.postEvent(try event(.leftMouseUp), atStart: false)

    let target = try XCTUnwrap(view.hitTest(view.convert(location, from: nil)))
    target.mouseDown(with: try event(.leftMouseDown))

    try await Task.sleep(for: .milliseconds(300))
  }

  private func newWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
  }

  /// Catches typed text reaching a text field of a PDF shown in the viewer, through a click on
  /// the field and then text input to the view's first responder.
  func testTypedTextDoesNotReachATextField() async throws {
    let window = newWindow()
    let (_, view) = try await shown(window)
    let page = try XCTUnwrap(view.document?.page(at: 0))
    let field = try XCTUnwrap(page.annotations.first { $0.fieldName == "text" })

    try await click(field, in: view, window: window)

    (window.firstResponder as? NSTextInputClient)?.insertText(
      "hello", replacementRange: NSRange(location: NSNotFound, length: 0))

    XCTAssertNil(field.widgetStringValue)
  }

  /// Catches a click that toggles a checkbox of a PDF shown in the viewer.
  func testClickDoesNotToggleACheckbox() async throws {
    let window = newWindow()
    let (_, view) = try await shown(window)
    let page = try XCTUnwrap(view.document?.page(at: 0))
    let box = try XCTUnwrap(page.annotations.first { $0.fieldName == "check" })
    let before = box.buttonWidgetState

    try await click(box, in: view, window: window)

    XCTAssertEqual(box.buttonWidgetState, before)
  }
}
