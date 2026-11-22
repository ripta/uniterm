#if DEBUG
  import AppKit
  import Foundation
  import QuestionForm
  import QuestionsApplet
  import ScriptWire
  import WindowKit

  /// Opens forms in the Questions pane from files, so a UI test can ask one without the wire. Only
  /// a debug build compiles it, and it runs only when `UNITERM_TEST_QUESTIONS_DIR` names a folder.
  ///
  /// A request is a `*.json` file the test writes into the folder. The hook takes it, renames it to
  /// `*.json.taken`, and writes what happened beside it.
  ///
  ///     {"requester": "build", "name": "Build script", "pane": "Pane 3", "spec": {...}}
  ///     {"command": "end", "requester": "build"}
  ///     {"command": "discard", "requester": "build"}
  ///     {"command": "pane-closed", "requester": "build"}
  ///
  /// `NAME.opened` holds `opened`, `reused`, or the busy reason. `NAME.outcome.json` holds the
  /// outcome the script would receive. A refused spec writes `NAME.error`.
  @MainActor
  final class QuestionsTestHook {
    private let directory: URL
    private let windows: WindowSet
    private weak var applet: QuestionsApplet?
    private var timer: Timer?
    private var forms: [String: FormSpec] = [:]

    init(directory: URL, windows: WindowSet) {
      self.directory = directory
      self.windows = windows
    }

    func start() {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
      }
    }

    private func poll() {
      let names =
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".outcome.json") }
        .sorted() ?? []

      for name in names { take(name) }
    }

    private func take(_ name: String) {
      let file = directory.appendingPathComponent(name)
      let base = String(name.dropLast(".json".count))
      let taken = directory.appendingPathComponent(name + ".taken")

      guard let data = try? Data(contentsOf: file) else { return }

      try? FileManager.default.removeItem(at: taken)
      try? FileManager.default.moveItem(at: file, to: taken)

      do {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let requester = request["requester"] as? String
        else { throw HookError.message("the request has no requester") }

        if let command = request["command"] as? String {
          try run(command, requester: requester)
        } else {
          try open(request, requester: requester, base: base)
        }
      } catch {
        write("\(error)", to: base + ".error")
      }
    }

    private func run(_ command: String, requester: String) throws {
      guard let applet else { throw HookError.message("no Questions pane is open") }

      switch command {
      case "end": applet.end(requester: requester)
      case "discard":
        if let tab = applet.tab(forRequester: requester) { applet.discard(tab: tab) }
      case "pane-closed": applet.askingPaneDidClose(forRequester: requester)
      default: throw HookError.message("unknown command \(command)")
      }
    }

    private func open(_ request: [String: Any], requester key: String, base: String) throws {
      guard let name = request["name"] as? String, let object = request["spec"] else {
        throw HookError.message("the request needs a name and a spec")
      }

      let spec = try FormSpecReader.decode(try JSONSerialization.data(withJSONObject: object))
      let pane = (request["pane"] as? String).map { QuestionsRequester.AskingPane.open(label: $0) }
      let requester = QuestionsRequester(key: key, name: name, askingPane: pane ?? .none)

      guard let pane = try questionsPane() else { throw HookError.message("no window") }

      let result = pane.open(spec, for: requester) { [weak self] outcome in
        self?.write(outcome, spec: spec, to: base + ".outcome.json")
      }

      switch result {
      case .opened(_, let reused): write(reused ? "reused" : "opened", to: base + ".opened")
      case .busy(let reason): write("busy \(reason)", to: base + ".opened")
      }
    }

    /// The Questions pane the hook last used, or a new one beside the largest pane.
    private func questionsPane() throws -> QuestionsApplet? {
      if let applet, !applet.isClosed { return applet }

      guard let controller = windows.activeController else { return nil }

      let created = QuestionsApplet()

      guard controller.placeRoutedInLargestPane(created) != nil else {
        throw HookError.message("the window has no room for a Questions pane")
      }

      applet = created

      return created
    }

    private func write(_ outcome: FormOutcome, spec: FormSpec, to name: String) {
      let value = outcome.scriptValue(form: 1, spec: spec) ?? .record(["outcome": .string("ended")])

      guard
        let data = try? JSONSerialization.data(
          withJSONObject: Self.json(value), options: [.sortedKeys])
      else { return }

      try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func write(_ text: String, to name: String) {
      try? Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func json(_ value: ScriptValue) -> Any {
      switch value {
      case .null: return NSNull()
      case .bool(let flag): return flag
      case .integer(let number): return number
      case .number(let number): return number
      case .string(let text): return text
      case .array(let items): return items.map(json)
      case .record(let fields): return fields.mapValues(json)
      }
    }

    private enum HookError: Error { case message(String) }
  }
#endif
