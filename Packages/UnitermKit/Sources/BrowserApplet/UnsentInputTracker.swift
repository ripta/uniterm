import BrowserModel
import WebKit

/// Knows whether a tab holds edited form input that a close would lose.
///
/// The script lives in an isolated content world, and so does its message handler, so no script in
/// the page's own world can reach either. The handler is a thin proxy that holds the tracker
/// weakly. WebKit retains a handler for as long as its controller lives, and a strong reference
/// back to the tab would make the web view, its controller, the handler, and the tab a cycle.
@MainActor
final class UnsentInputTracker {
  /// The world the script and the handler share. Nothing else runs in it.
  static let world = WKContentWorld.world(name: "uniterm.unsent-input")

  /// Whether some frame holds edited input.
  var isMarked: Bool { ledger.isMarked }

  /// Called after the mark changes.
  var onChange: (() -> Void)?

  private var ledger = UnsentInputLedger()
  private weak var controller: WKUserContentController?
  private var proxy: Proxy?

  init() {}

  /// Registers the script and the handler on `controller`. A controller takes one handler of a
  /// name in a world, and a second would raise an exception, so every web view gets its own
  /// controller and one install.
  func install(in controller: WKUserContentController) {
    guard self.controller == nil else { return }

    let proxy = Proxy(tracker: self)

    controller.add(proxy, contentWorld: Self.world, name: UnsentInputScript.handlerName)
    controller.addUserScript(
      WKUserScript(
        source: UnsentInputScript.source, injectionTime: .atDocumentStart,
        forMainFrameOnly: false, in: Self.world))

    self.controller = controller
    self.proxy = proxy
  }

  /// Takes the handler and the script off the controller, so a web view that outlives the tab
  /// reaches nothing of the tab's.
  func remove() {
    controller?.removeScriptMessageHandler(
      forName: UnsentInputScript.handlerName, contentWorld: Self.world)
    controller?.removeAllUserScripts()

    controller = nil
    proxy = nil
    ledger.clear()
  }

  /// One frame's report. Anything that is not a frame token and a real boolean is dropped.
  func receive(_ body: Any) {
    guard let report = UnsentInputReport(body: body) else { return }

    if ledger.apply(report) { onChange?() }
  }

  /// A load began, or the content process stopped. The input that was marked is gone.
  func clear() {
    if ledger.clear() { onChange?() }
  }

  @MainActor
  private final class Proxy: NSObject, WKScriptMessageHandler {
    private weak var tracker: UnsentInputTracker?

    init(tracker: UnsentInputTracker) {
      self.tracker = tracker
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      tracker?.receive(message.body)
    }
  }
}
