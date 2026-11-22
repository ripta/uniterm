#if DEBUG
  import AppKit
  import Foundation
  import QuestionForm
  import PaneModel
  import QuestionsApplet
  import ScriptHost
  import ScriptWire
  import WindowKit

  /// Opens forms in the Questions pane from files, so a UI test can ask one without a script. Only
  /// a debug build compiles it, and it runs only when `UNITERM_TEST_QUESTIONS_DIR` names a folder.
  ///
  /// A form opens through the window layer's own entry, the one the host calls for a script's
  /// `open-form`. The placement, the focus, and the badge are the real ones. Only the call's path
  /// to the window layer is skipped, which the package tests and `ScriptRunUITests` cover.
  ///
  /// A request is a `*.json` file the test writes into the folder. The hook takes it, renames it to
  /// `*.json.taken`, and writes what happened beside it.
  ///
  ///     {"requester": "build", "name": "Build script", "pane": "Pane 3", "spec": {...}}
  ///     {"command": "end", "requester": "build"}
  ///     {"command": "discard", "requester": "build"}
  ///     {"command": "pane-closed", "requester": "build"}
  ///
  /// The `pane` is the pane the form is asked from, by its label. Without one, the first pane in
  /// the window asks.
  ///
  /// `NAME.opened` holds `opened`, `reused`, or the busy reason. `NAME.outcome.json` holds the
  /// outcome the script would receive. A refused spec writes `NAME.error`.
  @MainActor
  final class QuestionsTestHook {
    private let directory: URL
    private let windows: WindowSet
    private let scripting: WindowScripting
    private var timer: Timer?

    init(directory: URL, windows: WindowSet) {
      self.directory = directory
      self.windows = windows
      scripting = WindowScripting(windows: windows)
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
      guard let controller = windows.activeController else { throw HookError.message("no window") }

      switch command {
      case "end": scripting.endForms(requester: requester, window: controller.scriptWindowID)
      case "discard":
        scripting.discardForm(requester: requester, window: controller.scriptWindowID)
      case "pane-closed":
        guard let applet = controller.questionsApplet else {
          throw HookError.message("no Questions pane is open")
        }

        applet.askingPaneDidClose(forRequester: requester)
      default: throw HookError.message("unknown command \(command)")
      }
    }

    private func open(_ request: [String: Any], requester key: String, base: String) throws {
      guard let name = request["name"] as? String, let object = request["spec"] else {
        throw HookError.message("the request needs a name and a spec")
      }

      guard let controller = windows.activeController else { throw HookError.message("no window") }

      let spec = try FormSpecReader.decode(try JSONSerialization.data(withJSONObject: object))
      guard let asker = Self.pane(labeled: request["pane"] as? String) ?? controller.paneIDs.first
      else { throw HookError.message("the window has no pane") }

      let caller = ScriptCaller(
        connection: 0, window: controller.scriptWindowID, pane: asker)

      let existing = controller.questionsApplet
      let reused = existing?.tab(forRequester: key) != nil

      do {
        try scripting.openForm(
          spec, requester: FormRequester(key: key, name: name), caller: caller
        ) { [weak self] outcome in
          self?.write(outcome, spec: spec, to: base + ".outcome.json")
        }
      } catch let error as ScriptCallError {
        write("busy \(error.text)", to: base + ".opened")

        return
      }

      write(reused ? "reused" : "opened", to: base + ".opened")
    }

    private static func pane(labeled label: String?) -> NodeID? {
      guard let label, label.hasPrefix("Pane "), let number = UInt64(label.dropFirst(5)) else {
        return nil
      }

      return NodeID(rawValue: number)
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
