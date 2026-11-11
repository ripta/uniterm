import AppKit
import AppletFixtures
import XCTest

@testable import AppletKit

/// Shared dispatch, the one path every applet command takes, from a remote caller or an exec
/// driver alike. The queue is stepped by hand, so each test controls exactly when delivery runs.
///
/// These prove the order of the checks, delivery in order within a per-turn bound, the second
/// authority check at delivery, and that an applet with no commands refuses them all. They cannot
/// prove who the caller is. The window's and the driver's tests prove that.
@MainActor
final class ControlDispatcherTests: XCTestCase {
  private var pending: [@MainActor () -> Void] = []

  private func dispatcher(perTurn: Int = 32, queued: Int = 256) -> ControlDispatcher {
    ControlDispatcher(maximumQueued: queued, deliveriesPerTurn: perTurn) { [weak self] body in
      self?.pending.append(body)
    }
  }

  private func turn() {
    let bodies = pending
    pending = []
    for body in bodies { body() }
  }

  private func submission(
    _ name: String, _ arguments: JSONValue = .object([:]), type: String = SlidesFixture.typeID,
    version: Int = 1
  ) -> AppletCommandSubmission {
    AppletCommandSubmission(
      appletType: type, schemaVersion: version, name: name, arguments: arguments)
  }

  private func deck(_ titles: [String]) -> JSONValue {
    .object(["titles": .array(titles.map(JSONValue.string))])
  }

  /// Catches a check that runs out of order or not at all: each refused submission must be
  /// answered at once, with the right code, and leave the applet unchanged.
  func testEveryCheckRefusesBeforeAnyEffect() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    var codes: [AppletCommandError.Code] = []

    let refused: [(AppletCommandSubmission, ControlDispatcher.Authority)] = [
      (submission("set-deck", deck(["a"])), { AppletCommandError(.refused, "no") }),
      (submission("set-deck", deck(["a"]), type: "fixture-chart"), { nil }),
      (submission("set-deck", deck(["a"]), version: 2), { nil }),
      (submission("set-deck", deck(["a"]), version: 0), { nil }),
      (submission("launch-run"), { nil }),
      (submission("set-deck", .object(["titles": .string("a")])), { nil }),
      (submission("set-deck", .object(["titles": .array([]), "extra": .bool(true)])), { nil }),
      (submission("show-slide", .object(["index": .number(1.5)])), { nil }),
      (submission("show-slide", .array([])), { nil }),
    ]

    for (submitted, authority) in refused {
      dispatch.submit(submitted, to: applet, authority: authority) { result in
        if case .failure(let error) = result { codes.append(error.code) }
      }
    }

    XCTAssertEqual(
      codes,
      [
        .refused, .unsupportedApplet, .unsupportedVersion, .unsupportedVersion, .unknownCommand,
        .badArgument, .badArgument, .badArgument, .badArgument,
      ])
    XCTAssertEqual(dispatch.queuedCount, 0)
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(applet.titles, [])
  }

  /// Catches a grant revoked between validation and delivery that still takes effect.
  func testAuthorityRevokedAfterValidationLeavesNoEffect() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    let allowed = Flag()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(
      submission("set-deck", deck(["a"])), to: applet,
      authority: { allowed.on ? nil : AppletCommandError(.refused, "revoked") },
      reply: { result = $0 })

    XCTAssertNil(result)
    allowed.on = false
    turn()

    XCTAssertEqual(result, .failure(AppletCommandError(.refused, "revoked")))
    XCTAssertEqual(applet.titles, [])
  }

  /// Catches commands delivered out of order, or a flood delivered in one main-thread turn.
  func testDeliveryIsInOrderAndBoundedPerTurn() {
    let dispatch = dispatcher(perTurn: 2)
    let applet = SlidesFixture()
    var replies: [Int] = []

    dispatch.submit(
      submission("set-deck", deck(["a", "b", "c", "d", "e"])), to: applet, authority: { nil },
      reply: { _ in })

    for index in [3, 1, 4, 0] {
      dispatch.submit(
        submission("show-slide", .object(["index": .number(Double(index))])), to: applet,
        authority: { nil },
        reply: { result in
          if case .success(.object(let fields)) = result, case .number(let shown)? = fields["index"]
          {
            replies.append(Int(shown))
          }
        })
    }

    turn()
    XCTAssertEqual(replies, [3])
    turn()
    XCTAssertEqual(replies, [3, 1, 4])
    turn()
    XCTAssertEqual(replies, [3, 1, 4, 0])
    XCTAssertEqual(applet.index, 0)
  }

  /// Catches a queue that grows without bound, or a refusal past the bound that drops a command
  /// with no answer.
  func testAFullQueueRefusesWithBusyAndAnswersEveryCommand() {
    let dispatch = dispatcher(queued: 3)
    let applet = SlidesFixture()
    var answers: [AppletCommandError.Code?] = []

    for _ in 0..<5 {
      dispatch.submit(
        submission("status"), to: applet, authority: { nil },
        reply: { result in
          switch result {
          case .success: answers.append(nil)
          case .failure(let error): answers.append(error.code)
          }
        })
    }

    XCTAssertEqual(answers, [.busy, .busy])
    turn()
    XCTAssertEqual(answers, [.busy, .busy, nil, nil, nil])
  }

  /// Catches an applet error that is reported as success, or an applet error that changes state.
  func testAnAppletErrorChangesNothing() {
    let dispatch = dispatcher()
    let applet = SlidesFixture()
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(submission("set-deck", deck(["only"])), to: applet) {
      nil
    } reply: { _ in
    }
    dispatch.submit(submission("show-slide", .object(["index": .number(5)])), to: applet) {
      nil
    } reply: {
      result = $0
    }
    turn()

    guard case .failure(let error)? = result else {
      return XCTFail("\(String(describing: result))")
    }

    XCTAssertEqual(error.code, .badArgument)
    XCTAssertEqual(applet.index, 0)
  }

  /// Catches an applet without the hook, such as a terminal or a REPL, taking a command.
  func testAnAppletWithNoCommandsRefusesEveryCommand() {
    let dispatch = dispatcher()
    let applet = PlaceholderApplet(
      keeping: AppletDescription(type: "x", version: 1, payload: .null), reason: "synthetic")
    var result: Result<JSONValue, AppletCommandError>?

    dispatch.submit(submission("status", type: "placeholder"), to: applet) {
      nil
    } reply: {
      result = $0
    }

    XCTAssertEqual(
      result, .failure(AppletCommandError(.refused, "this pane's applet takes no commands")))
  }

  /// Catches an outlet that keeps events while no driver is attached, which would grow a queue.
  func testEventsWithNoSinkGoNowhere() {
    let applet = SlidesFixture()
    let sink = RecordingSink()

    for _ in 0..<10_000 { applet.button.performClick(nil) }

    XCTAssertFalse(applet.events.isConnected)
    XCTAssertTrue(applet.events.connect(sink))

    applet.button.performClick(nil)

    XCTAssertEqual(sink.events.count, 1, "events from before the sink were kept")

    applet.close()

    XCTAssertTrue(sink.closed)
    XCTAssertFalse(applet.events.connect(sink), "a closed outlet took a sink")
  }
}

@MainActor
private final class RecordingSink: AppletEventSink {
  var events: [String] = []
  var closed = false

  func deliver(event name: String, data: JSONValue) { events.append(name) }
  func outletClosed() { closed = true }
}

@MainActor
private final class Flag {
  var on = true
}
