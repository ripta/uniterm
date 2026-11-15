import ControllerPackage
import ControllerTestSupport
import ControllerTrust
import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Declared script files end to end: the real command, the real Janet reader and loader, and the
/// app's own admission, against a host whose window layer is a fake.
///
/// As in the controller tests, the bundle's command is a signed copy of the SwiftPM helper.
@MainActor
final class DeclaredFileRunTests: XCTestCase {
  private var directory: URL!
  private var runs: URL!
  private var work: URL!
  private var trust: URL!
  private var host: ScriptHost!

  private var seenReviews: [ControllerReview] = []
  private var seenRuns: [ControllerRun] = []
  private var reviewWatch: ChangeObservers.Token?

  /// How the tests answer each startup review. A test that answers itself sets it to nil.
  private var reviewAnswer: ControllerReviewChoice? = .allowForSession

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    runs = work.appendingPathComponent("runs")
    trust = work.appendingPathComponent("trust")

    try startHost()
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: runs)
    try? FileManager.default.removeItem(at: work)
  }

  private func startHost() throws {
    let center = StatusCenter()

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: FakeWindowAPI(),
      controllers: ControllerSettings(
        runsRoot: runs, helper: BundleHelperIdentity(helperURL: try HardenedHelper.url()),
        trustDirectory: trust))
    host.start()
    reviewWatch = host.changes.add { [weak self] in
      guard let self else { return }

      for review in host.controllerReviews where !seenReviews.contains(review) {
        seenReviews.append(review)

        if let answer = reviewAnswer {
          Task { @MainActor in await self.host.decideReview(review.id, answer) }
        }
      }
    }
    host.onControllersChanged = { [weak self] in
      guard let self else { return }

      for run in host.allControllerRuns() where !seenRuns.contains(run) {
        seenRuns.append(run)
      }
    }

    recordTestProcessAsSessionRoot(host)
  }

  // MARK: Helpers

  private var runFolders: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []
  }

  private func source(_ text: String, named name: String = "tidy") throws -> URL {
    let file = work.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).janet")

    try Data(text.utf8).write(to: file)

    return file
  }

  /// A file whose first form declares `permissions` under `header`, followed by `body`.
  private func declared(
    _ body: String, header: String = #"{:name "Tidy"}"#,
    permissions: [String] = ["{:kind :pane-control :version 1}"], named name: String = "tidy"
  ) throws -> URL {
    try source(
      "(declare-permissions \(header)\n  \(permissions.joined(separator: "\n  ")))\n\n\(body)\n",
      named: name)
  }

  private func environment() -> [String: String] {
    var inherited = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }

    inherited["UNITERM_SOCKET"] = nil

    return inherited
  }

  private func start(
    _ file: URL, allow: [String] = [], arguments: [String] = [], input: Pipe? = nil
  ) throws -> (process: Process, output: LineCollector, errors: LineCollector) {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()

    process.executableURL = try HardenedHelper.url()
    process.arguments =
      ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] } + [file.path]
      + arguments
    process.environment = environment()
    process.standardInput = input ?? FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors

    let collected = (process, LineCollector(output.fileHandleForReading))
    let failures = LineCollector(errors.fileHandleForReading)

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
      if watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
    }

    return (collected.0, collected.1, failures)
  }

  private func run(_ file: URL, allow: [String] = [], arguments: [String] = []) async throws
    -> HelperRun
  {
    let process = Process()

    process.executableURL = try HardenedHelper.url()
    process.arguments =
      ["run", "--socket", host.instanceAddress] + allow.flatMap { ["--allow", $0] } + [file.path]
      + arguments
    process.environment = environment()
    process.currentDirectoryURL = work
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()

    let watchdog = process

    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
      if watchdog.isRunning { kill(watchdog.processIdentifier, SIGKILL) }
    }

    return await ScriptFixtures.finish(process)
  }

  // MARK: Review

  /// Catches a declared file that runs before the user has seen its powers. The review lists the
  /// declared powers and the declared name, the file has printed nothing while it waits, and once
  /// the user answers, the file runs.
  func testAValidDeclarationShowsAReviewListingItsPowersBeforeAnyCodeRuns() async throws {
    reviewAnswer = nil

    let file = try declared(
      #"(print "ran")"#,
      permissions: [
        "{:kind :pane-control :version 1}", "{:kind :clipboard-read :version 1}",
      ])
    let started = try start(file)

    defer { if started.process.isRunning { started.process.terminate() } }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, "Tidy")
    XCTAssertEqual(review.identity.artifact, .file)
    XCTAssertEqual(review.requested, [.paneControl, .clipboardRead])
    XCTAssertEqual(started.output.text, "", "the file ran before the review was answered")
    XCTAssertTrue(started.process.isRunning)
    XCTAssertEqual(runFolders.count, 1, "the file was not snapshotted")

    let failure = await host.decideReview(review.id, .allowOnce)

    XCTAssertNil(failure)
    expect(await waitUntil { !started.process.isRunning }, "the file never ran")
    XCTAssertEqual(started.process.terminationStatus, 0, started.errors.text)
    XCTAssertEqual(started.output.text, "ran\n")
    expect(await waitUntil { self.runFolders.isEmpty }, "the snapshot outlived its run")
  }

  /// Catches a review that titles a file by something other than its declared name, and an
  /// unnamed file that is not shown by its file name.
  func testAnUnnamedFileIsShownByItsFileName() async throws {
    reviewAnswer = nil

    let file = try source(
      "(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n", named: "plain-name")
    let started = try start(file)

    defer { if started.process.isRunning { started.process.terminate() } }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, file.lastPathComponent)
    XCTAssertEqual(review.identity.controllerID, file.lastPathComponent)

    await host.decideReview(review.id, .deny)
    expect(await waitUntil { !started.process.isRunning }, "the denied file kept running")
    XCTAssertNotEqual(started.process.terminationStatus, 0)
    XCTAssertTrue(started.errors.text.contains("You denied this"), started.errors.text)
    XCTAssertEqual(started.output.text, "")
  }

  /// Catches a file name that reaches the review as it stands. A name can hold a newline or a
  /// direction override, and the review prints its title and ID, so neither may carry one.
  func testAHostileFileNameIsCleanedBeforeItIsShown() async throws {
    reviewAnswer = nil

    let file = work.appendingPathComponent("evil\u{202E}\nVersion: forged.janet")

    try Data("(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n".utf8)
      .write(to: file)

    let started = try start(file)

    defer { if started.process.isRunning { started.process.terminate() } }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    let review = try XCTUnwrap(host.controllerReviews.first)

    XCTAssertEqual(review.name, "script file")
    XCTAssertEqual(review.identity.controllerID, "script file")
    XCTAssertFalse(review.identity.controllerID.contains("\n"))

    await host.decideReview(review.id, .deny)
  }

  /// Catches a long file name cut with nothing to show it. A cut name keeps its start and its
  /// extension and shows an ellipsis between, and fits a descriptor name's limit. A short name is
  /// left alone.
  func testALongFileNameKeepsItsExtensionAndShowsTheCut() {
    let long = "uniterm-ui-AD52E6A1-4F3B-42C9-B6D5-7C1E0A9F2B33-declared-file.janet"
    let title = ScriptHost.fileTitle(long)

    XCTAssertLessThanOrEqual(title.utf8.count, ControllerDescriptor.maxNameBytes)
    XCTAssertTrue(title.hasPrefix("uniterm-ui-AD52"), title)
    XCTAssertTrue(title.hasSuffix("declared-file.janet"), title)
    XCTAssertTrue(title.contains("\u{2026}"), title)
    XCTAssertEqual(ScriptHost.fileTitle("tidy.janet"), "tidy.janet")
    XCTAssertEqual(ScriptHost.fileTitle("bad\u{202E}name.janet"), "script file")

    let wide = String(repeating: "\u{00E9}", count: 80) + ".janet"
    let cut = ScriptHost.fileTitle(wide)

    XCTAssertLessThanOrEqual(cut.utf8.count, ControllerDescriptor.maxNameBytes)
    XCTAssertTrue(cut.hasSuffix(".janet") && cut.contains("\u{2026}"), cut)
  }

  /// Catches a command that runs the file at its path and not the copy the app made. The file is
  /// rewritten while the review waits, and the run still prints what the reviewed bytes print.
  func testTheCommandRunsTheSnapshotAndAnEditAfterReviewChangesNothing() async throws {
    reviewAnswer = nil

    let file = try declared(#"(print "reviewed")"#)
    let started = try start(file)

    defer { if started.process.isRunning { started.process.terminate() } }

    expect(await waitUntil { !self.host.controllerReviews.isEmpty }, "no review was queued")

    try Data(
      "(declare-permissions {:kind :pane-control :version 1})\n(print \"edited\")\n".utf8
    ).write(to: file)

    let review = try XCTUnwrap(host.controllerReviews.first)

    await host.decideReview(review.id, .allowForSession)
    expect(await waitUntil { !started.process.isRunning }, "the file never ran")
    XCTAssertEqual(started.output.text, "reviewed\n")
  }

  /// Catches a remembered version that asks again for the same bytes, and one that covers an edit.
  func testTrustThisVersionSkipsTheNextReviewAndAnEditedFileGetsAFreshOne() async throws {
    reviewAnswer = .trustVersion

    let file = try declared(#"(print "one")"#)
    let first = try await run(file)

    XCTAssertEqual(first.status, 0, first.standardError)
    XCTAssertEqual(first.standardOutput, "one\n")
    XCTAssertEqual(seenReviews.count, 1)

    let second = try await run(file)

    XCTAssertEqual(second.status, 0, second.standardError)
    XCTAssertEqual(second.standardOutput, "one\n")
    XCTAssertEqual(seenReviews.count, 1, "trusted bytes asked again")
    XCTAssertEqual(seenRuns.last?.approval.displayText, "Trusted version")

    try Data(
      "(declare-permissions {:name \"Tidy\"} {:kind :pane-control :version 1})\n(print \"two\")\n"
        .utf8
    ).write(to: file)

    let edited = try await run(file)

    XCTAssertEqual(edited.standardOutput, "two\n", edited.standardError)
    XCTAssertEqual(seenReviews.count, 2, "an edited file ran without a fresh review")
  }

  /// Catches a file approval that lives in the controller policy file, which an older build would
  /// move aside.
  func testAFileApprovalIsWrittenToItsOwnPolicyFile() async throws {
    reviewAnswer = .trustVersion

    let result = try await run(try declared(#"(print "x")"#))

    XCTAssertEqual(result.status, 0, result.standardError)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: trust.path)) ?? []

    XCTAssertTrue(names.contains("files.json"), "\(names)")
    XCTAssertFalse(names.contains("policy.json"), "\(names)")
  }

  // MARK: Refusals

  /// Catches a refused declaration that still reaches a review or runs. The fixture covers a
  /// refusal made by the command's reader and one made by the app's.
  func testARefusedDeclarationShowsNoReviewAndRunsNothing() async throws {
    reviewAnswer = nil

    let fromTheReader = try source(
      "(declare-permissions {:kind :pane-control :version 1})\n(print :ran)\n"
        + "(declare-permissions {:kind :pane-control :version 1})\n")
    let reader = try await run(fromTheReader)

    XCTAssertNotEqual(reader.status, 0)
    XCTAssertEqual(reader.standardOutput, "")
    XCTAssertTrue(reader.standardError.contains("appears again"), reader.standardError)

    let fromTheApp = try declared(
      #"(print :ran)"#, permissions: ["{:kind :pane-control :version 2}"])
    let app = try await run(fromTheApp)

    XCTAssertNotEqual(app.status, 0)
    XCTAssertEqual(app.standardOutput, "")
    XCTAssertTrue(
      app.standardError.contains("pane-control version 2 is not one this uniterm knows"),
      app.standardError)

    let native = try declared(
      #"(print :ran)"#, permissions: [#"{:kind :capability :version 1 :name :ffi}"#])
    let refused = try await run(native)

    XCTAssertNotEqual(refused.status, 0)
    XCTAssertEqual(refused.standardOutput, "")
    XCTAssertTrue(refused.standardError.contains("cannot declare ffi"), refused.standardError)

    XCTAssertTrue(seenReviews.isEmpty)
    expect(await waitUntil { self.runFolders.isEmpty }, "a refused file left its snapshot")
  }

  /// Catches a misspelled declaration form that runs as if nothing was wrong. The binding exists
  /// for the exact name, so another spelling fails as an unbound symbol.
  func testAMisspelledFormFailsAsAnUnboundSymbol() async throws {
    let file = try declared(
      "(print :before)\n(declare-permisions {:kind :pane-control :version 1})\n(print :after)")
    let result = try await run(file)

    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(
      result.standardError.contains("unknown symbol declare-permisions"), result.standardError)
    XCTAssertFalse(result.standardOutput.contains("after"))
  }

  /// Catches a declared file that can load a file. An ordinary script beside it does import the
  /// same module, so the fixture proves the loader and not a missing file.
  func testAnImportFromADeclaredFileFindsNothing() async throws {
    try Data("(print :loaded)\n(def value 1)\n".utf8).write(
      to: work.appendingPathComponent("sibling.janet"))

    let ordinary = try source("(import ./sibling)\n(print sibling/value)\n", named: "ordinary")
    let control = try await run(ordinary, allow: ["fs-read"])

    XCTAssertEqual(control.status, 0, control.standardError)
    XCTAssertTrue(control.standardOutput.contains("loaded"), "the fixture proves nothing")

    let file = try declared("(import ./sibling)\n(print :unreachable)")
    let result = try await run(file)

    XCTAssertNotEqual(result.status, 0)
    XCTAssertFalse(result.standardOutput.contains("loaded"), result.standardOutput)
    XCTAssertFalse(result.standardOutput.contains("unreachable"))
    XCTAssertTrue(result.standardError.contains("sibling"), result.standardError)
  }

  /// Catches a declared file that reaches the bundled module's calls without the power it
  /// declared. The error names the permission and the declaration, and the calls it did declare
  /// still run.
  func testACallNeedingAnUndeclaredPowerIsRefusedAndNamesThePermission() async throws {
    let file = try declared(
      """
      (import uniterm)
      (defn show [f]
        (let [[_ failure] (protect (f))]
          (print (if (string? failure) failure (string/format "%p" failure)))))
      (show (fn [] (uniterm/list-windows)))
      (show (fn [] (uniterm/write-clipboard "x")))
      """,
      permissions: ["{:kind :clipboard-read :version 1}"])
    let result = try await run(file)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(
      result.standardOutput.contains(
        "This script did not declare pane-control in its (declare-permissions ...) form"),
      result.standardOutput)
    XCTAssertTrue(
      result.standardOutput.contains("did not declare clipboard-write"), result.standardOutput)
  }

  /// Catches an empty declaration that grants more than posting status, and one that asks for a
  /// review it has nothing to put in.
  func testAnEmptyDeclarationRunsWithNoPowersBeyondPostingStatus() async throws {
    reviewAnswer = nil

    let file = try source(
      """
      (declare-permissions {:name "x"})
      (import uniterm)
      (uniterm/post-status :info "posted")
      (print (get (protect (uniterm/list-windows)) 1))
      """)
    let result = try await run(file)

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertTrue(result.standardOutput.contains("pane-control"), result.standardOutput)
    XCTAssertTrue(seenReviews.isEmpty, "an empty declaration asked for a review")
  }

  /// Catches an `--allow` for a capability the file did not declare, and one it did.
  func testAllowNamesOnlyDeclaredCapabilities() async throws {
    reviewAnswer = .allowForSession

    let note = work.appendingPathComponent("note.txt")

    try Data("12345".utf8).write(to: note)

    let file = try declared(
      "(print (length (slurp \"\(note.path)\")))",
      permissions: [#"{:kind :capability :version 1 :name :fs-read}"#])
    let undeclared = try await run(file, allow: ["net-connect"])

    XCTAssertNotEqual(undeclared.status, 0)
    XCTAssertEqual(undeclared.standardOutput, "")
    XCTAssertTrue(
      undeclared.standardError.contains(
        "--allow net-connect is not a capability the file declares"),
      undeclared.standardError)

    let denied = try await run(file)

    XCTAssertNotEqual(denied.status, 0)
    XCTAssertTrue(denied.standardError.contains("forbidden by sandbox"), denied.standardError)

    let granted = try await run(file, allow: ["fs-read"])

    XCTAssertEqual(granted.status, 0, granted.standardError)
    XCTAssertEqual(granted.standardOutput, "5\n")
  }

  // MARK: Paths

  /// Catches a symlink that is refused or run from the link's own bytes, and an `(dyn :args)` that
  /// starts with anything but the path the user typed.
  func testAFileReachedThroughASymlinkRunsAndArgsStartWithTheTypedPath() async throws {
    let file = try declared(#"(print (get (dyn :args) 0)) (print (get (dyn :args) 1))"#)
    let link = work.appendingPathComponent("link.janet")

    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    let result = try await run(link, arguments: ["extra"])

    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "\(link.path)\nextra\n")
  }
}
