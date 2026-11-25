import AppKit
import TerminalSurface

@main
enum UnitermMain {
  @MainActor
  static func main() {
    let debugEnvironment = InheritedEnvironment.scrubProcess().filter {
      $0.key.hasPrefix("UNITERM_")
    }

    #if DEBUG
      RecordingApplication.startIfAsked(by: debugEnvironment)
    #endif

    let application = NSApplication.shared
    let delegate = AppDelegate(debugEnvironment: debugEnvironment)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}
