#if DEBUG
  import AppKit
  import OSLog

  /// An `NSApplication` subclass that records each input event it takes off the queue.
  ///
  /// The debug launch makes this the shared instance by referencing it before anything reads
  /// `NSApplication.shared`. A control's nested tracking loop, such as a title-bar button's,
  /// dequeues through the same `nextEvent(matching:until:inMode:dequeue:)` method, so the override
  /// sees its events too. A press on the menu bar starts menu tracking outside this method, so that
  /// press has no record. The moves and keys the menu's loop takes do.
  ///
  /// AppKit merges queued moves, drags, and scroll events before they reach this method. A merged
  /// event leaves one record, so XCTest's numbered events show gaps in the records' user data.
  ///
  /// Each record goes to the unified log at the default level, with its fields marked public. A key
  /// event carries its key code and flags only when XCTest sent it, so a person's typing never
  /// reaches the log.
  @MainActor
  final class RecordingApplication: NSApplication {
    private let logger = Logger(subsystem: "dev.uniterm.app", category: "input-recording")
    private let keyWindowRecorder = KeyWindowRecorder()
    private var started = false

    /// Makes this class the shared application and starts recording, when a UI test launch sets
    /// `UNITERM_RECORD_INPUT=1`. It must run before anything reads `NSApplication.shared`, since
    /// the first read creates the shared instance from the class it is called on.
    static func startIfAsked(by environment: [String: String]) {
      guard environment["UNITERM_RECORD_INPUT"] == "1" else { return }

      guard let application = shared as? RecordingApplication else {
        Logger(subsystem: "dev.uniterm.app", category: "input-recording")
          .error("The shared application already existed, so no input is recorded")
        return
      }

      application.started = true
      application.logger.log("Recording input")
      application.keyWindowRecorder.start()
    }

    override func nextEvent(
      matching mask: NSEvent.EventTypeMask,
      until expiration: Date?,
      inMode mode: RunLoop.Mode,
      dequeue: Bool
    ) -> NSEvent? {
      let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)

      if started, dequeue, let event, Self.isRecorded(event.type) {
        record(event)
      }

      return event
    }

    private func record(_ event: NSEvent) {
      var fields = [
        "dequeued_at=\(Date.now.timeIntervalSinceReferenceDate)",
        "timestamp=\(event.timestamp)",
        "type=\(Self.name(of: event.type))",
        Self.describeSource(of: event),
      ]

      if let keyWindow {
        fields.append("key_window=\(keyWindow.windowNumber)")

        if let responder = keyWindow.firstResponder {
          fields.append("first_responder_class=\(type(of: responder))")

          let identifier = (responder as? NSView)?.accessibilityIdentifier() ?? ""

          if !identifier.isEmpty {
            fields.append("first_responder_id=\(identifier)")
          }
        }
      }

      if Self.isKey(event.type), Self.isFromXCTest(event) {
        fields.append("keycode=\(event.keyCode)")
        fields.append("flags=0x\(String(event.modifierFlags.rawValue, radix: 16))")
      }

      if !Self.isKey(event.type), let window = event.window {
        let location = event.locationInWindow
        fields.append("event_window=\(window.windowNumber)")
        fields.append("location=(\(location.x),\(location.y))")

        // A hit test on every move or drag would add main-thread work at about 100 events a second,
        // which could change the timing the record exists to observe.
        if Self.isPressReleaseOrWheel(event.type) {
          fields += Self.describeHitView(at: location, in: window)
        }
      }

      logger.log("\(fields.joined(separator: " "), privacy: .public)")
    }

    /// The hit test starts at the window's frame view, the content view's superview, so a press on
    /// a title-bar button resolves to that button.
    ///
    /// The frame view has no superview. So `hitTest` takes its point in window coordinates, which
    /// `locationInWindow` already is.
    private static func describeHitView(at location: NSPoint, in window: NSWindow) -> [String] {
      guard let root = window.contentView?.superview ?? window.contentView,
        let view = root.hitTest(location)
      else { return [] }

      var fields = ["hit_view_class=\(type(of: view))"]
      let identifier = view.accessibilityIdentifier()

      if !identifier.isEmpty {
        fields.append("hit_view_id=\(identifier)")
      }

      return fields
    }

    /// The posting process and the user data it set, which tell XCTest's events from a person's. A
    /// person's hardware events carry pid 0 and no user data.
    private static func describeSource(of event: NSEvent) -> String {
      guard let cgEvent = event.cgEvent else { return "source=unknown" }

      let userData = cgEvent.getIntegerValueField(.eventSourceUserData)
      let pid = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
      let stateID = cgEvent.getIntegerValueField(.eventSourceStateID)

      return "source_userdata=\(userData) source_pid=\(pid) source_stateid=\(stateID)"
    }

    /// XCTest's daemon, `testmanagerd`, posts every synthesized event with nonzero user data. An
    /// event counts as XCTest's only when it has nonzero user data and `testmanagerd` posted it.
    /// Another program that posts events with user data, such as a password manager typing for a
    /// person, does not pass, so its key codes never reach the log.
    private static func isFromXCTest(_ event: NSEvent) -> Bool {
      guard let cgEvent = event.cgEvent,
        cgEvent.getIntegerValueField(.eventSourceUserData) != 0
      else { return false }

      let pid = pid_t(truncatingIfNeeded: cgEvent.getIntegerValueField(.eventSourceUnixProcessID))
      return processName(of: pid) == "testmanagerd"
    }

    private static func processName(of pid: pid_t) -> String? {
      guard pid > 0 else { return nil }

      var buffer = [CChar](repeating: 0, count: 64)
      guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }

      return String(cString: buffer)
    }

    private static func isRecorded(_ type: NSEvent.EventType) -> Bool {
      isKey(type) || isPressReleaseOrWheel(type)
        || [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved].contains(type)
    }

    private static func isKey(_ type: NSEvent.EventType) -> Bool {
      [.keyDown, .keyUp, .flagsChanged].contains(type)
    }

    private static func isPressReleaseOrWheel(_ type: NSEvent.EventType) -> Bool {
      [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
        .otherMouseUp, .scrollWheel,
      ].contains(type)
    }

    private static func name(of type: NSEvent.EventType) -> String {
      switch type {
      case .keyDown: return "keyDown"
      case .keyUp: return "keyUp"
      case .flagsChanged: return "flagsChanged"
      case .leftMouseDown: return "leftMouseDown"
      case .leftMouseUp: return "leftMouseUp"
      case .leftMouseDragged: return "leftMouseDragged"
      case .rightMouseDown: return "rightMouseDown"
      case .rightMouseUp: return "rightMouseUp"
      case .rightMouseDragged: return "rightMouseDragged"
      case .otherMouseDown: return "otherMouseDown"
      case .otherMouseUp: return "otherMouseUp"
      case .otherMouseDragged: return "otherMouseDragged"
      case .mouseMoved: return "mouseMoved"
      case .scrollWheel: return "scrollWheel"
      default: return "type\(type.rawValue)"
      }
    }
  }

  /// Records each time one of the app's windows becomes key or stops being key. Another app's
  /// non-activating panel can take the keyboard while uniterm stays active, so the runner's
  /// frontmost record misses it. The key window's change is what shows it.
  @MainActor
  final class KeyWindowRecorder: NSObject {
    private let logger = Logger(subsystem: "dev.uniterm.app", category: "input-recording")

    func start() {
      let center = NotificationCenter.default

      center.addObserver(
        self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification,
        object: nil)
      center.addObserver(
        self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification,
        object: nil)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
      record("window_became_key", notification)
    }

    @objc private func windowResignedKey(_ notification: Notification) {
      record("window_resigned_key", notification)
    }

    private func record(_ change: String, _ notification: Notification) {
      guard let window = notification.object as? NSWindow else { return }

      let at = Date.now.timeIntervalSinceReferenceDate
      logger.log("\(change, privacy: .public) at=\(at) window=\(window.windowNumber)")
    }
  }
#endif
