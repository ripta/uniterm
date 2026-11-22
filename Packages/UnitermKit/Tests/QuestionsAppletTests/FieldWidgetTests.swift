import AppKit
import QuestionForm
import ScriptWire
import XCTest

@testable import QuestionsApplet

/// Proves each answer type's widget returns the answer shape the proposal's type table gives. A
/// widget is driven through its real controls, and its answer goes through the same outcome a
/// script receives. It cannot prove how a widget looks, which the UI tests attach in both
/// appearances.
@MainActor
final class FieldWidgetTests: XCTestCase {
  private func widget(_ body: String) throws -> (FieldWidget, FormSpec) {
    let spec = try FormSpecReader.decode(
      Data(#"{"items": [{"id": "q", "text": "Q?", \#(body)}]}"#.utf8))
    let widget = FieldWidget.make(spec.questions[0], styler: FormStyler(palette: .latte))

    return (widget, spec)
  }

  private func find<T: NSView>(_ type: T.Type, _ identifier: String, in view: NSView) -> T? {
    if let match = view as? T, view.accessibilityIdentifier() == identifier { return match }

    for subview in view.subviews {
      if let found = find(type, identifier, in: subview) { return found }
    }

    return nil
  }

  private func edit(_ field: NSTextField, to text: String) {
    field.stringValue = text
    field.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: field))
  }

  /// What the script receives for one question given this answer.
  private func received(_ spec: FormSpec, _ answer: FormAnswer?) -> ScriptValue? {
    let outcome = FormOutcome.submitted(
      submission: 1, action: "ok", answers: answer.map { ["q": $0] } ?? [:])

    guard case .record(let fields) = outcome.scriptValue(form: 1, spec: spec),
      case .record(let answers) = fields["answers"]
    else { return nil }

    return answers["q"]
  }

  private func record(_ widget: FieldWidget) -> () -> FormAnswer? {
    var last: FormAnswer?

    widget.onChange = { last = $0 }

    return { last }
  }

  func testStringAndTextReturnStrings() throws {
    for (body, text) in [
      (#""type": "string""#, "one line"),
      (#""type": "text""#, "single"),
    ] {
      let (widget, spec) = try widget(body)
      let last = record(widget)

      edit(try XCTUnwrap(find(NSTextField.self, "question-q", in: widget.root)), to: text)

      XCTAssertEqual(received(spec, last()), .string(text))
    }
  }

  func testMultilineTextReturnsAString() throws {
    let (widget, spec) = try widget(#""type": "text", "multiline": true"#)
    let last = record(widget)
    let view = try XCTUnwrap(find(AreaTextView.self, "question-q", in: widget.root))

    view.string = "two\nlines"
    view.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: view))

    XCTAssertEqual(received(spec, last()), .string("two\nlines"))
  }

  /// Catches a widget that lets the user type past the cap the spec reader computed, which would
  /// make the reply cut an answer.
  func testAStringFieldStopsAtItsByteCap() throws {
    let (widget, _) = try widget(#""type": "string", "validate": {"maxLength": 3}"#)
    let last = record(widget)
    let field = try XCTUnwrap(find(NSTextField.self, "question-q", in: widget.root))

    edit(field, to: String(repeating: "x", count: 20))

    XCTAssertEqual(field.stringValue.utf8.count, 12)
    XCTAssertEqual(last(), .text(String(repeating: "x", count: 12)))
  }

  func testIntegerAndNumberReturnNumbers() throws {
    let (integer, integerSpec) = try widget(#""type": "integer""#)
    let integerLast = record(integer)

    edit(try XCTUnwrap(find(NSTextField.self, "question-q", in: integer.root)), to: " 42 ")

    XCTAssertEqual(received(integerSpec, integerLast()), .integer(42))

    let (number, numberSpec) = try widget(#""type": "number""#)
    let numberLast = record(number)

    edit(try XCTUnwrap(find(NSTextField.self, "question-q", in: number.root)), to: "-2.5")

    XCTAssertEqual(received(numberSpec, numberLast()), .number(-2.5))
  }

  /// Catches a boolean that has two states when it has no default, which cannot say "no answer",
  /// and one that has three when it has a default.
  func testBooleanHasThreeStatesWithoutADefaultAndTwoWithOne() throws {
    let (open, openSpec) = try widget(#""type": "boolean""#)
    let openLast = record(open)
    let box = try XCTUnwrap(find(NSButton.self, "question-q", in: open.root))

    XCTAssertEqual(box.state, .mixed)
    XCTAssertEqual(received(openSpec, .unanswered), .null)

    var seen: Set<NSControl.StateValue> = []

    for _ in 0..<3 {
      box.performClick(nil)
      seen.insert(box.state)

      switch box.state {
      case .on: XCTAssertEqual(openLast(), .boolean(true))
      case .off: XCTAssertEqual(openLast(), .boolean(false))
      default: XCTAssertEqual(openLast(), .unanswered)
      }
    }

    XCTAssertEqual(seen, [.on, .off, .mixed])

    let (fixed, _) = try widget(#""type": "boolean", "default": false"#)
    let fixedBox = try XCTUnwrap(find(NSButton.self, "question-q", in: fixed.root))

    XCTAssertEqual(fixedBox.state, .off)

    fixedBox.performClick(nil)
    fixedBox.performClick(nil)

    XCTAssertEqual(fixedBox.state, .off)
  }

  func testAFewChoicesShowAsRadiosAndOtherReturnsTheTypedText() throws {
    let (widget, spec) = try widget(
      #""type": "choice", "choices": ["red", "green"], "other": true"#)
    let last = record(widget)
    let green = try XCTUnwrap(find(NSButton.self, "question-q-choice-1", in: widget.root))

    green.performClick(nil)

    XCTAssertEqual(received(spec, last()), .string("green"))

    let other = try XCTUnwrap(find(NSButton.self, "question-q-choice-other", in: widget.root))

    other.performClick(nil)
    edit(try XCTUnwrap(find(NSTextField.self, "question-q-other", in: widget.root)), to: "teal")

    XCTAssertEqual(received(spec, last()), .string("teal"))
    XCTAssertEqual(green.state, .off)
  }

  /// Catches a long choice list that stays a column of radios, and a popup that cannot say "no
  /// answer". Six choices show in a pop-up that starts on its placeholder.
  func testManyChoicesShowInAPopupThatStartsUnanswered() throws {
    let (widget, spec) = try widget(
      #""type": "choice", "choices": ["a", "b", "c", "d", "e", "f"]"#)
    let last = record(widget)
    let popup = try XCTUnwrap(find(NSPopUpButton.self, "question-q", in: widget.root))

    XCTAssertEqual(popup.titleOfSelectedItem, "Choose\u{2026}")
    XCTAssertEqual(received(spec, .unanswered), .null)

    popup.selectItem(at: 3)
    _ = popup.target?.perform(popup.action, with: popup)

    XCTAssertEqual(received(spec, last()), .string("c"))

    popup.selectItem(at: 0)
    _ = popup.target?.perform(popup.action, with: popup)

    XCTAssertEqual(last(), .unanswered)
  }

  /// Catches a pop-up that shows a real choice while its answer is empty. Clearing an optional
  /// choice that has a default returns the pop-up to its placeholder, so what shows is what the
  /// script receives.
  func testClearingAnOptionalPopUpShowsThePlaceholderNotAChoice() throws {
    let (widget, _) = try widget(
      #""type": "choice", "choices": ["a", "b", "c", "d", "e", "f"], "default": "b""#)
    let last = record(widget)
    let popup = try XCTUnwrap(find(NSPopUpButton.self, "question-q", in: widget.root))

    XCTAssertEqual(popup.titleOfSelectedItem, "b")

    try XCTUnwrap(find(NSButton.self, "question-q-clear", in: widget.root)).performClick(nil)

    XCTAssertEqual(popup.titleOfSelectedItem, "Choose\u{2026}")
    XCTAssertEqual(last(), .unanswered)
  }

  func testAChoiceDefaultFillsTheSelection() throws {
    let (widget, _) = try widget(#""type": "choice", "choices": ["a", "b"], "default": "b""#)
    let radio = try XCTUnwrap(find(NSButton.self, "question-q-choice-1", in: widget.root))

    XCTAssertEqual(radio.state, .on)
  }

  /// Catches a multi answer out of order, and a box that lets the user pick past the entry cap.
  func testMultiReturnsTheChoicesInOrderAndStopsAtItsLimit() throws {
    let (widget, spec) = try widget(
      #""type": "multi", "choices": ["a", "b", "c"], "validate": {"maxItems": 2}"#)
    let last = record(widget)
    let boxes = try (0..<3).map {
      try XCTUnwrap(find(NSButton.self, "question-q-choice-\($0)", in: widget.root))
    }

    boxes[2].performClick(nil)
    boxes[0].performClick(nil)

    XCTAssertEqual(received(spec, last()), .array([.string("a"), .string("c")]))
    XCTAssertFalse(boxes[1].isEnabled)

    boxes[0].performClick(nil)

    XCTAssertTrue(boxes[1].isEnabled)
    XCTAssertEqual(last(), .list(["c"]))
  }

  func testColorReturnsSRGBWithAlpha() throws {
    let (widget, spec) = try widget(#""type": "color""#)
    let last = record(widget)
    let well = try XCTUnwrap(find(NSColorWell.self, "question-q", in: widget.root))

    XCTAssertEqual(received(spec, .unanswered), .null)

    well.color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.5)
    _ = well.target?.perform(well.action, with: well)

    XCTAssertEqual(received(spec, last()), .string("#ff800080"))
  }

  func testAColorDefaultShowsInTheWell() throws {
    let (widget, _) = try widget(##""type": "color", "default": "#336699""##)
    let well = try XCTUnwrap(find(NSColorWell.self, "question-q", in: widget.root))
    let srgb = try XCTUnwrap(well.color.usingColorSpace(.sRGB))

    XCTAssertEqual(srgb.redComponent, 0.2, accuracy: 0.001)
    XCTAssertEqual(srgb.greenComponent, 0.4, accuracy: 0.001)
    XCTAssertEqual(srgb.blueComponent, 0.6, accuracy: 0.001)
  }

  /// Catches a file answer in the wrong shape. A single file is a path, and `multiple` is an array
  /// of paths, held to the question's entry limit.
  func testFileReturnsAPathOrAnArrayOfPaths() throws {
    let (single, singleSpec) = try widget(#""type": "file""#)
    let singleLast = record(single)

    try XCTUnwrap(single as? FileField).take(["/tmp/a"])

    XCTAssertEqual(received(singleSpec, singleLast()), .string("/tmp/a"))

    let (many, manySpec) = try widget(
      #""type": "file", "multiple": true, "validate": {"maxItems": 2}"#)
    let manyLast = record(many)

    try XCTUnwrap(many as? FileField).take(["/tmp/a", "/tmp/b", "/tmp/c"])

    XCTAssertEqual(received(manySpec, manyLast()), .array([.string("/tmp/a"), .string("/tmp/b")]))
  }

  /// Catches the file panel's modes and types drifting from the spec. The panel itself runs in
  /// the user's process, so the UI test opens it.
  func testTheFileButtonNamesWhatItPicks() throws {
    for (body, title) in [
      (#""type": "file""#, "Choose file\u{2026}"),
      (#""type": "file", "mode": "directory""#, "Choose folder\u{2026}"),
      (#""type": "file", "mode": "save""#, "Choose where to save\u{2026}"),
      (#""type": "file", "multiple": true"#, "Choose files\u{2026}"),
    ] {
      let (widget, _) = try widget(body)
      let button = try XCTUnwrap(find(NSButton.self, "question-q", in: widget.root))

      XCTAssertEqual(button.title, title)
    }
  }
}
