import Foundation

/// What the user asked a new pane to run.
public enum AppletChoice: Sendable, Equatable {
  /// A terminal that starts the user's login shell.
  case terminalShell

  /// A terminal that runs one program, given as a command line.
  case terminalProgram(command: String)

  /// A data viewer with nothing open, started in the pane's directory.
  case dataViewer

  /// A map viewer, started in the pane's directory.
  case mapViewer
}
