import AppKit
import AppletKit
import Foundation
import GeoData
import XCTest

@testable import MapViewerApplet

/// Editing a file's pins through the applet: what the map shows, what Save writes, undo, the
/// unsaved state the close dialog reads, and changes on disk.
@MainActor
final class MapPinEditingTests: XCTestCase {
  private func load(_ applet: MapViewerApplet, _ file: URL) async {
    applet.replaceSource(with: file, startDirectory: file.deletingLastPathComponent().path)
    await applet.opening?.value
  }

  private func settle(_ applet: MapViewerApplet) async {
    await applet.editing?.value
  }

  private func mixedFile(_ scratch: GeoScratch) throws -> URL {
    try scratch.write(
      "places.geojson",
      GeoFixtures.collection([
        GeoFixtures.point("A", 1, 1), GeoFixtures.line, GeoFixtures.point("B", 2, 2),
      ]))
  }

  /// Catches an edit the map shows but Save loses, a save that drops what the map cannot show,
  /// and a pane that still says it is edited after saving. An added pin shows at once, the pane
  /// is edited until Save, and the file on disk then holds the pin beside the original line.
  func testAnAddedPinShowsAndSaveWritesItBesideWhatTheMapCannotShow() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 5, longitude: 6))
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.count, 3)
    XCTAssertTrue(applet.isDirty)
    XCTAssertEqual(applet.unsavedWork, AppletUnsavedWork(label: "places.geojson"))
    XCTAssertEqual(applet.title, "places.geojson \u{2014} Edited")

    let saved = await applet.save()

    XCTAssertTrue(saved)
    XCTAssertFalse(applet.isDirty)
    XCTAssertNil(applet.unsavedWork)

    let onDisk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(onDisk.contains(GeoFixtures.line), onDisk)
    XCTAssertTrue(onDisk.contains("[6.0, 5.0]"), onDisk)
  }

  /// Catches an undo that does not put the file's bytes back, and a redo that is lost because the
  /// undo registered a new action instead. Undo of a removal brings the pin and the clean state
  /// back. Redo removes it again.
  func testUndoAndRedoPutBackTheExactBytes() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let original = try Data(contentsOf: file)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    let pin = try XCTUnwrap(applet.filePinsShown.first { $0.label == "B" })
    applet.remove(pin)
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
    XCTAssertEqual(applet.undoManager.undoActionName, "Remove Pin")

    applet.undoManager.undo()
    await settle(applet)

    XCTAssertEqual(applet.document, original)
    XCTAssertFalse(applet.isDirty)
    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A", "B"])
    XCTAssertTrue(applet.undoManager.canRedo)

    applet.undoManager.redo()
    await settle(applet)

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["A"])
  }

  /// Catches a second edit that lands on stale pin IDs. While the first edit's pins are being
  /// read, a second edit is refused, so a removal that renumbers pins cannot misdirect it.
  func testAnEditWaitsForTheLastOneToLand() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 2))
    XCTAssertFalse(applet.canEdit)

    let before = applet.document
    applet.addPin(at: GeoCoordinate(latitude: 3, longitude: 4))
    XCTAssertEqual(applet.document, before)

    await settle(applet)
    XCTAssertTrue(applet.canEdit)
  }

  /// Catches a map with no file that cannot keep its pins. Its pins are unsaved, Save asks where,
  /// and the chosen file becomes the pane's file and is restored with it.
  func testPinsOnAMapWithNoFileSaveToANewFile() async throws {
    let scratch = try GeoScratch(self)
    let target = scratch.url.appendingPathComponent("new.geojson")
    let applet = MapViewerApplet(startDirectory: scratch.url.path)
    var asked: [(String, String?)] = []
    applet.chooseSaveLocation = { name, folder, _ in
      asked.append((name, folder))
      return target
    }

    applet.addPin(at: GeoCoordinate(latitude: 48.85, longitude: 2.35))
    await settle(applet)

    XCTAssertEqual(applet.unsavedWork?.label, "Untitled")

    let saved = await applet.saveUnsavedWork()

    XCTAssertTrue(saved)
    XCTAssertEqual(asked.first?.0, "Pins.geojson")
    XCTAssertEqual(asked.first?.1, scratch.url.path)
    XCTAssertFalse(applet.isDirty)
    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).path, target.path)

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
    XCTAssertEqual((object?["features"] as? [Any])?.count, 1)
  }

  /// Catches a cancelled Save As that counts as saved, which would let a close drop the pins.
  func testACancelledSaveAsIsNotASave() async {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.chooseSaveLocation = { _, _, _ in nil }

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 1))
    await settle(applet)

    let saved = await applet.saveUnsavedWork()

    XCTAssertFalse(saved)
    XCTAssertTrue(applet.isDirty)
  }

  /// Catches a save that silently overwrites another program's change. Save asks first. Cancel
  /// writes nothing, and Overwrite writes the edits.
  func testSaveAsksBeforeOverwritingAChangeOnDisk() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    var choices: [SaveConflictChoice] = [.cancel, .overwrite]
    var asked = 0
    applet.resolveConflict = { _, _ in
      asked += 1
      return choices.removeFirst()
    }
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 9, longitude: 9))
    await settle(applet)

    let theirs = GeoFixtures.collection([GeoFixtures.point("Theirs", 0, 0)])
    try Data(theirs.utf8).write(to: file)

    let cancelled = await applet.save()
    XCTAssertFalse(cancelled)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), theirs)

    let overwritten = await applet.save()
    XCTAssertTrue(overwritten)
    XCTAssertEqual(try Data(contentsOf: file), applet.document)
    XCTAssertEqual(asked, 2)
  }

  /// Catches a save that resets the file's permissions, as a plain atomic write does.
  func testSaveKeepsTheFilesPermissions() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    chmod(file.path, 0o600)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 2))
    await settle(applet)
    _ = await applet.save()

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  /// Catches a pane that goes stale when another program changes its file, and one that drops
  /// the user's edits to follow the change. A clean pane reads the file again. An edited pane
  /// keeps its edits and says the file changed.
  func testAChangeOnDiskReloadsACleanPaneAndWarnsAnEditedOne() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    try Data(GeoFixtures.collection([GeoFixtures.point("C", 3, 3)]).utf8).write(to: file)
    applet.fileChangedOnDisk()
    await applet.opening?.value

    XCTAssertEqual(applet.filePinsShown.map(\.label), ["C"])

    applet.addPin(at: GeoCoordinate(latitude: 4, longitude: 4))
    await settle(applet)
    try Data(GeoFixtures.collection([GeoFixtures.point("D", 5, 5)]).utf8).write(to: file)
    applet.fileChangedOnDisk()

    XCTAssertEqual(applet.filePinsShown.count, 2)
    XCTAssertTrue(applet.isDirty)
    XCTAssertTrue(
      applet.content.noticeLines.contains {
        $0.hasPrefix("The file changed on disk")
      })
  }

  /// Catches a watcher that never fires, or one that stops after an editor replaces the file by
  /// renaming a new one over it.
  func testTheWatcherSeesWritesAndReplacements() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    var changes = 0
    let fired = expectation(description: "watcher")
    fired.expectedFulfillmentCount = 2
    let watcher = FileWatcher(url: file) {
      changes += 1
      if changes <= 2 { fired.fulfill() }
    }
    defer { watcher.stop() }

    let replacement = scratch.url.appendingPathComponent("replacement.geojson")
    try Data("{}".utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
    try await Task.sleep(for: .milliseconds(50))
    try Data("{} ".utf8).write(to: file)

    await fulfillment(of: [fired], timeout: 5)
  }

  /// Catches a closed pane whose unsaved pins are gone on reopen. The undo-only part of its
  /// description carries them, and a reopen shows them as still unsaved. The layout file never
  /// holds them.
  func testReopenBringsBackUnsavedPins() async throws {
    let scratch = try GeoScratch(self)
    let file = try mixedFile(scratch)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, file)

    applet.addPin(at: GeoCoordinate(latitude: 7, longitude: 7))
    await settle(applet)

    let description = applet.describe()
    XCTAssertNotNil(description.undoState)
    XCTAssertNil(description.withoutUndoState.undoState)

    let reopened = try MapViewerApplet(restoring: description)
    reopened.start()
    await reopened.opening?.value
    await settle(reopened)

    XCTAssertEqual(reopened.filePinsShown.count, 3)
    XCTAssertTrue(reopened.isDirty)
  }

  /// Catches a context menu that adds nothing, or adds the pin somewhere other than where the
  /// user clicked.
  func testAddPinHereAddsAPinAtTheClick() async throws {
    let applet = MapViewerApplet(startDirectory: nil)
    applet.content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    applet.content.layoutSubtreeIfNeeded()

    let items = applet.content.contextItems(atWindowPoint: NSPoint(x: 300, y: 200))
    XCTAssertEqual(items.map(\.title), ["Add Pin Here"])

    (items.first as? ClosureMenuItem)?.perform()
    await settle(applet)

    let center = applet.content.mapView.convert(
      NSPoint(x: 300, y: 200), toCoordinateFrom: applet.content.mapView)
    let pin = try XCTUnwrap(applet.filePinsShown.first)
    XCTAssertEqual(pin.coordinate.latitude, center.latitude, accuracy: 0.0001)
    XCTAssertEqual(pin.coordinate.longitude, center.longitude, accuracy: 0.0001)
  }

  /// Catches an editor whose Done writes nothing, or writes a glyph the reader would drop.
  func testTheEditorWritesItsFieldsAndRefusesABadGlyph() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    let pin = try XCTUnwrap(applet.filePinsShown.first { $0.label == "A" })
    let editor = PinEditorController(pin: pin, layerAccent: .blue, palette: .latte)
    _ = editor.view
    editor.onDone = { applet.update(pin, to: $0) }

    editor.labelField.stringValue = "Alpha"
    editor.accentMenu.selectItem(withTitle: "Peach")
    editor.glyphField.stringValue = "too long name!"
    editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    XCTAssertFalse(editor.doneButton.isEnabled)

    editor.glyphField.stringValue = "\u{2605}"
    editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    editor.done()
    await settle(applet)

    let edited = try XCTUnwrap(applet.filePinsShown.first { $0.label == "Alpha" })
    XCTAssertEqual(edited.accent, .peach)
    XCTAssertEqual(edited.glyph, PinGlyph("\u{2605}"))
  }

  /// Catches a pin list that disagrees with the map, or a filter that misses.
  func testThePinListFollowsThePinsAndFilters() async throws {
    let scratch = try GeoScratch(self)
    let applet = MapViewerApplet(startDirectory: nil)
    await load(applet, try mixedFile(scratch))

    applet.content.setPinList(visible: true)
    let list = try XCTUnwrap(applet.content.pinList)
    XCTAssertEqual(list.shown.map(\.label), ["A", "B"])

    list.filter("b")
    XCTAssertEqual(list.shown.map(\.label), ["B"])

    list.filter("")
    applet.addPin(at: GeoCoordinate(latitude: 8, longitude: 8))
    await settle(applet)
    XCTAssertEqual(list.shown.count, 3)

    applet.content.setPinList(visible: false)
    XCTAssertNil(applet.content.pinList)
  }
}

/// Remove Pin's Cmd-Delete belongs to the map, never to a text field over it.
@MainActor
final class RemovePinKeyTests: XCTestCase {
  /// Catches Cmd-Delete in the place search removing the selected pin. The command is on only
  /// while the map has the keyboard.
  func testRemovePinIsOffWhileATextFieldHasTheKeyboard() async throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = applet.content
    defer { window.close() }

    applet.addPin(at: GeoCoordinate(latitude: 1, longitude: 1))
    await applet.editing?.value

    let annotation = try XCTUnwrap(
      applet.content.mapView.annotations.compactMap { $0 as? MapPinAnnotation }.first)
    applet.content.mapView.selectAnnotation(annotation, animated: false)

    let remove = try XCTUnwrap(
      MapViewerApplet.commandSet.commands.first { $0.name == "remove-pin" })

    window.makeFirstResponder(applet.content.mapView)
    XCTAssertTrue(remove.isAvailable(applet))

    let field = NSTextField()
    applet.content.addSubview(field)
    window.makeFirstResponder(field)
    XCTAssertFalse(remove.isAvailable(applet))
  }
}
