import AppKit
import AppletKit
import AppletTestSupport
import XCTest

@testable import TerminalApplet
@testable import TerminalSurface

/// A terminal's scrollback from a quit to the next launch: the store's files, and the applet that
/// writes them at quit and reads them on restore.
@MainActor
final class TerminalScrollbackTests: XCTestCase {
  private var directory: URL!
  private var store: ScrollbackStore!

  /// A session holds its applet weakly, and an applet holds its host weakly.
  private var retained: [TerminalApplet] = []
  private var hosts: [RecordingHost] = []

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-scrollback-\(UUID().uuidString)", directoryHint: .isDirectory)
    store = ScrollbackStore(directory: directory)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func files() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
  }

  private func started(_ applet: TerminalApplet) -> TerminalApplet {
    let host = RecordingHost()
    host.answer = true
    hosts.append(host)
    applet.host = host
    applet.start(origin: .restore)
    retained.append(applet)
    return applet
  }

  private func shell(tabs: Int, engine: FakeEngine) -> TerminalApplet {
    let applet = started(
      TerminalApplet(
        engine: engine, workingDirectory: "/tmp", directoryExists: { _ in true },
        scrollbackStore: store))

    for _ in 1..<max(tabs, 1) { applet.openTab() }
    return applet
  }

  private func restore(_ description: AppletDescription, engine: FakeEngine) throws
    -> TerminalApplet
  {
    started(
      try TerminalApplet(
        engine: engine, restoring: description, directoryExists: { _ in true },
        scrollbackStore: store))
  }

  // MARK: Store

  /// Catches saved output that other users could read, and a take that leaves the file behind.
  func testTheStoreKeepsPrivateFilesUntilTaken() throws {
    let id = try store.write("secret\n")

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

    let file = directory.appending(path: "\(id).txt")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    XCTAssertEqual(store.take(id), "secret\n")
    XCTAssertEqual(files(), [])
    XCTAssertNil(store.take(id))
  }

  /// Catches an ID from a layout file that reaches outside the store. Only an ID the store makes
  /// is read or deleted.
  func testAnIDThatIsNotTheStoresIsRefused() throws {
    let outside = directory.deletingLastPathComponent().appending(path: "outside-\(UUID()).txt")
    try Data("outside\n".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }

    let id = try store.write("inside\n")

    for bad in [
      "../\(outside.deletingPathExtension().lastPathComponent)", "", "x", id.lowercased(),
    ] {
      XCTAssertNil(store.take(bad), bad)
      store.remove(bad)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    XCTAssertEqual(files(), ["\(id).txt"])
  }

  /// Catches files from quits whose layout never came back piling up for good. A write deletes
  /// files older than the age, and keeps newer ones.
  func testAWriteDeletesStaleFiles() throws {
    let old = try store.write("old\n")
    let recent = try store.write("recent\n")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-ScrollbackStore.staleAge - 60)],
      ofItemAtPath: directory.appending(path: "\(old).txt").path)

    let new = try store.write("new\n")

    XCTAssertEqual(files(), ["\(new).txt", "\(recent).txt"].sorted())
  }

  // MARK: Quit and restore

  /// Catches a relaunch that loses a tab's output, shows it in the wrong tab, or leaves it on
  /// disk. Two tabs save at quit. The restored tabs show their own text, and the files are gone.
  func testEachTabShowsItsOwnOutputAfterARelaunch() throws {
    let before = FakeEngine()
    let applet = shell(tabs: 2, engine: before)
    before.sessions[0].scrollback = "first tab\n"
    before.sessions[1].scrollback = "second tab\n"

    applet.willQuit()
    let description = applet.describe()
    XCTAssertEqual(files().count, 2)

    let after = FakeEngine()
    _ = try restore(description, engine: after)

    XCTAssertEqual(after.sessions.map(\.launch.replay), ["first tab\n", "second tab\n"])
    XCTAssertEqual(files(), [])
  }

  /// Catches scrollback saved outside a quit. A description made while the app runs holds no ID,
  /// so the layout saved on every change never points at a file, and nothing is written.
  func testOnlyAQuitSavesScrollback() throws {
    let engine = FakeEngine()
    let applet = shell(tabs: 1, engine: engine)
    engine.sessions[0].scrollback = "running\n"

    let description = try TerminalDescription.decode(applet.describe())

    XCTAssertNil(description.tabs[0].scrollback)
    XCTAssertEqual(files(), [])
  }

  /// Catches a tab with no output that saves an empty file, and a terminal with no store that
  /// fails at quit.
  func testATabWithNoOutputSavesNothing() throws {
    let engine = FakeEngine()
    let applet = shell(tabs: 2, engine: engine)
    engine.sessions[1].scrollback = "only the second\n"

    applet.willQuit()
    let saved = try TerminalDescription.decode(applet.describe())

    XCTAssertNil(saved.tabs[0].scrollback)
    XCTAssertNotNil(saved.tabs[1].scrollback)
    XCTAssertEqual(files().count, 1)

    let bare = started(TerminalApplet(engine: engine, directoryExists: { _ in true }))
    bare.willQuit()
    XCTAssertNil(try TerminalDescription.decode(bare.describe()).tabs[0].scrollback)
  }

  /// Catches a restored tab whose shell never started losing its text at the next quit. The text it
  /// was going to show is saved again.
  func testATabThatHasNotStartedSavesTheTextItWasGoingToShow() throws {
    let id = try store.write("carried\n")
    let description = try TerminalDescription(
      mode: .shell, tabs: [.init(workingDirectory: "/tmp", scrollback: id)]
    ).appletDescription()

    let applet = try TerminalApplet(
      engine: FakeEngine(), restoring: description, directoryExists: { _ in true },
      scrollbackStore: store)
    retained.append(applet)

    applet.willQuit()
    let saved = try XCTUnwrap(
      TerminalDescription.decode(applet.describe()).tabs[0].scrollback)

    XCTAssertEqual(store.take(saved), "carried\n")
  }

  /// Catches a missing file that fails the restore. A tab whose file is gone starts with no text.
  func testAMissingFileRestoresATabWithNoText() throws {
    let description = try TerminalDescription(
      mode: .shell, tabs: [.init(workingDirectory: "/tmp", scrollback: UUID().uuidString)]
    ).appletDescription()

    let engine = FakeEngine()
    _ = try restore(description, engine: engine)

    XCTAssertEqual(engine.sessions.count, 1)
    XCTAssertNil(engine.sessions[0].launch.replay)
  }

  /// Catches a program-mode terminal that saves output, or keeps a saved file it will never show.
  /// Its tab comes back waiting to run, so its file is deleted unread.
  func testAProgramTerminalSavesNoneAndDropsAnySavedFile() throws {
    let engine = FakeEngine()
    let program = started(
      try TerminalApplet(engine: engine, program: "/bin/sleep 30", directoryExists: { _ in true }))
    engine.sessions[0].scrollback = "program output\n"
    program.willQuit()
    XCTAssertEqual(files(), [])

    let id = try store.write("left over\n")
    let description = try TerminalDescription(
      mode: .program, command: "/bin/sleep 30",
      tabs: [.init(workingDirectory: "/tmp", scrollback: id)]
    ).appletDescription()

    let restored = try restore(description, engine: FakeEngine())

    XCTAssertTrue(restored.isAwaitingRun)
    XCTAssertEqual(files(), [])
  }
}
