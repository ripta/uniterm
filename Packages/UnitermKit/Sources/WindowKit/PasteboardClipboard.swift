import AppKit
import ScriptHost

/// The general pasteboard, as the typed clipboard requests of scripts and drivers reach it. Only
/// plain text crosses, in both directions.
///
/// A read can wait on the app that put the text there, so it runs off the main actor, as ADR-08
/// asks. A write hands the text to the pasteboard server and waits on no other app.
@MainActor
public final class PasteboardClipboard: ScriptClipboard {
  public init() {}

  public func readText() async -> String? {
    await Task.detached { NSPasteboard.general.string(forType: .string) }.value
  }

  public func writeText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
