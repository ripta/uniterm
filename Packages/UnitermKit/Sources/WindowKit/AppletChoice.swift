import Foundation
import GeoData

/// What the user asked a new pane to run.
public enum AppletChoice: Sendable, Equatable {
  /// A terminal that starts the user's login shell.
  case terminalShell

  /// A terminal that runs one program, given as a command line.
  case terminalProgram(command: String)

  /// A data viewer with nothing open, started in the pane's directory.
  case dataViewer

  /// A map viewer, started in the pane's directory. It shows `region` when the user picked a place,
  /// and its own default view otherwise.
  case mapViewer(region: GeoRegion?)

  /// An image viewer with nothing open, started in the pane's directory.
  case imageViewer

  /// A text viewer with nothing open, started in the pane's directory.
  case textViewer

  /// A Janet REPL. It starts in the home folder, whatever pane it is opened from.
  case repl

  /// A browser with no page loaded. It has no directory, so the pane's directory goes unused.
  case browser

  /// A browser whose first tab loads this address when the pane starts. The address already
  /// passed the controller rule for addresses, so the browser loads it as it is. Only a layout
  /// request makes one.
  case browserPage(URL)

  /// An applet type the window declares beyond the built-in choices, such as a hosted fixture in
  /// a debug build. The app's factory decides whether it can make one, and throws when it cannot.
  /// No launcher entry offers it.
  case hosted(typeID: String)
}

extension AppletChoice {
  /// True for a browser pane, with or without a first page.
  var isBrowser: Bool {
    switch self {
    case .browser, .browserPage: return true
    default: return false
    }
  }
}
