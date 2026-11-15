import AppKit
internal import GhosttyKit

/// What libghostty reports about one surface, copied out of the callback so it can cross to the
/// main actor.
enum SurfaceNotice: Sendable {
  case title(String)
  case workingDirectory(String)
  case notification(title: String, body: String)
  case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
  case bell
  case mouseShape(MouseShape)
  case cellSize(width: UInt32, height: UInt32)
  case configChanged
  case exited
}

enum MouseShape: Sendable {
  case standard
  case text
  case pointer
  case crosshair
  case notAllowed
}

/// A pointer handed back to libghostty later. It crosses actors only to be passed back unchanged.
struct OpaqueToken: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer?
}

/// What a clipboard read asks for. libghostty asks for plain text alone for a paste, an OSC 52
/// read, and some Kitty reads. It asks for the type listing alone for a paste event. Anything else
/// is a Kitty read.
struct ClipboardRead: Equatable {
  static let plainText = "text/plain"

  let types: [String]
  let wantsListing: Bool

  var isPlainText: Bool { types == [Self.plainText] && !wantsListing }
  var isListingOnly: Bool { types.isEmpty && wantsListing }
}

/// The C callbacks that libghostty calls. They run on any thread, so each one copies what it needs
/// and hops to the main actor before it touches a Swift object. Nothing here unwinds through C.
enum GhosttyCallbacks {
  /// Built here, in a nonisolated context. A closure written inside a main-actor initializer would
  /// inherit that isolation, and libghostty calls these from its own threads.
  static func runtimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: false,
      wakeup_cb: { GhosttyCallbacks.wakeup($0) },
      action_cb: { GhosttyCallbacks.action($0, $1, $2) },
      read_clipboard_cb: { GhosttyCallbacks.readClipboard($0, $1, $2, $3, $4, $5) },
      confirm_read_clipboard_cb: { GhosttyCallbacks.confirmReadClipboard($0, $1, $2, $3) },
      write_clipboard_cb: { GhosttyCallbacks.writeClipboard($0, $1, $2, $3, $4) },
      close_surface_cb: { GhosttyCallbacks.closeSurface($0, $1) })
  }

  static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }

    let target = Unmanaged<WakeupTarget>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { target.engine?.tick() }
    }
  }

  static func action(
    _ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
  ) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    else { return false }

    let notice: SurfaceNotice

    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      guard let title = action.action.set_title.title else { return true }

      notice = .title(String(cString: title))

    case GHOSTTY_ACTION_PWD:
      guard let pwd = action.action.pwd.pwd else { return true }

      notice = .workingDirectory(String(cString: pwd))

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let raw = action.action.desktop_notification
      notice = .notification(
        title: raw.title.map { String(cString: $0) } ?? "",
        body: raw.body.map { String(cString: $0) } ?? "")

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let raw = action.action.command_finished
      notice = .commandFinished(
        exitCode: raw.exit_code < 0 ? nil : Int(raw.exit_code), durationNanoseconds: raw.duration)

    case GHOSTTY_ACTION_RING_BELL:
      notice = .bell

    case GHOSTTY_ACTION_MOUSE_SHAPE:
      notice = .mouseShape(Self.shape(action.action.mouse_shape))

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      notice = .configChanged

    case GHOSTTY_ACTION_CELL_SIZE:
      let raw = action.action.cell_size
      notice = .cellSize(width: raw.width, height: raw.height)

    // libghostty asks here as the child ends. Taking it keeps libghostty from printing "Press any
    // key to close" and waiting for that key, which it does for every launch with a command. The
    // pane's owner decides what an ended session does, so the exit is reported now.
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      notice = .exited

    case GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_RENDERER_HEALTH,
      GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_INITIAL_SIZE,
      GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_MOUSE_OVER_LINK,
      GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE:
      return true

    default:
      return false
    }

    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { view.receive(notice) }
    }
    return true
  }

  /// Runs on the main thread, either inside the surface view's own paste call or while libghostty
  /// ticks. libghostty does not say which kind of request this is, so the view tells them apart by
  /// the MIME types asked for and by whether its own paste is in progress.
  static func readClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?, _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimeCount: Int, _ wantsListing: Bool
  ) -> ghostty_clipboard_read_result_e {
    guard Thread.isMainThread, let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }

    let types = (0..<mimeCount).compactMap { index in mimes?[index].map { String(cString: $0) } }
    let request = ClipboardRead(types: types, wantsListing: wantsListing)

    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    let token = OpaqueToken(pointer: state)
    return MainActor.assumeIsolated { view.answerClipboardRead(request, state: token) }
  }

  /// libghostty asks here before it sends clipboard data to a program, before an unsafe paste, and
  /// before a Kitty clipboard write. The request type is known only here, so this is where uniterm
  /// denies Kitty reads and writes.
  static func confirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
  ) {
    guard let userdata else { return }

    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    let token = OpaqueToken(pointer: state)
    let text = confirm.flatMap {
      plainText(in: $0.pointee.contents, count: $0.pointee.contents_len)
    }

    let kind: TerminalClipboardRequest.Kind?
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: kind = .read
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE: kind = .unsafePaste
    default: kind = nil
    }

    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let kind else {
          view.denyClipboard(state: token)
          return
        }

        view.askAboutClipboard(kind: kind, text: text ?? "", state: token)
      }
    }
  }

  /// Takes copies from the surface and OSC 52 writes. With `clipboard-write` set to `ask`, an OSC
  /// 52 write arrives with `confirm` set, and it is allowed without asking. A Kitty write never
  /// arrives here, since the confirm callback denies it first.
  static func writeClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool
  ) {
    guard let userdata, let plain = plainText(in: content, count: count) else { return }

    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { view.writeClipboard(plain) }
    }
  }

  /// libghostty calls this when the child ended. Freeing the surface from inside this callback
  /// would be a use after free, so the event always arrives on a later main-queue turn.
  static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }

    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { view.receive(.exited) }
    }
  }

  /// The first plain-text representation. The data carries an explicit length and need not end in
  /// a NUL.
  private static func plainText(
    in content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
  ) -> String? {
    guard let content else { return nil }

    for index in 0..<count {
      let item = content[index]
      guard let mime = item.mime, String(cString: mime) == ClipboardRead.plainText else { continue }
      guard let data = item.data else { return "" }

      let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(data), count: item.len)
      return String(decoding: bytes, as: UTF8.self)
    }

    return nil
  }

  private static func shape(_ raw: ghostty_action_mouse_shape_e) -> MouseShape {
    switch raw {
    case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .text
    case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointer
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .notAllowed
    default: return .standard
    }
  }
}

/// Lets the wakeup callback reach the engine without keeping it alive.
final class WakeupTarget: @unchecked Sendable {
  nonisolated(unsafe) weak var engine: GhosttyTerminalEngine?
}
