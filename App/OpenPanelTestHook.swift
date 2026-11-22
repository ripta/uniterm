#if DEBUG
  import AppKit
  import AppletKit

  /// An open panel that a UI test answers through files, so the system's panel never shows.
  ///
  /// A pick first writes the `.asked` file beside the answer file. It says `sheet` when the panel
  /// would hang from a window and `modal` when it would not, then the start directory. The test
  /// reads it to know the panel was asked for, and from where.
  ///
  /// The pick then waits for the answer file, as the panel waits for a person. It holds one
  /// absolute path per line, and an empty file answers cancel. The pick removes it once read, so
  /// the next pick waits for a new answer. No answer within the wait answers cancel.
  struct OpenPanelTestHook {
    let answerFile: URL

    static let answerWait = Duration.seconds(30)

    var askedFile: URL { answerFile.appendingPathExtension("asked") }

    @MainActor
    func pick(_ request: OpenPanelRequest, over window: NSWindow?) async -> [URL] {
      let asked = "\(window == nil ? "modal" : "sheet") \(request.directory.path)\n"
      try? Data(asked.utf8).write(to: askedFile)

      let clock = ContinuousClock()
      let deadline = clock.now + Self.answerWait

      while clock.now < deadline {
        if let answer = try? String(contentsOf: answerFile, encoding: .utf8) {
          try? FileManager.default.removeItem(at: answerFile)

          return answer.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }

        try? await Task.sleep(for: .milliseconds(100))
      }

      return []
    }
  }
#endif
