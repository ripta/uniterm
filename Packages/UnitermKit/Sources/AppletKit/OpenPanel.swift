import AppKit
import UniformTypeIdentifiers

/// What an open panel is asked to show. The start directory is always explicit, so the panel never
/// falls back to the folder AppKit remembers from the last time it ran.
public struct OpenPanelRequest: Sendable, Equatable {
  public var directory: URL
  public var allowsMultipleSelection: Bool

  /// The file types the panel lets the user pick. Folders stay choosable whatever this says. Nil
  /// lets every file be picked.
  public var contentTypes: [UTType]?

  public init(directory: URL, allowsMultipleSelection: Bool, contentTypes: [UTType]? = nil) {
    self.directory = directory
    self.allowsMultipleSelection = allowsMultipleSelection
    self.contentTypes = contentTypes
  }

  /// The request for a pane that reports `currentDirectory`. A pane with none, or one whose folder
  /// is gone, starts the panel in the home folder.
  public init(
    startingIn currentDirectory: String?, allowsMultipleSelection: Bool,
    contentTypes: [UTType]? = nil
  ) {
    self.init(
      directory: Self.startDirectory(for: currentDirectory),
      allowsMultipleSelection: allowsMultipleSelection, contentTypes: contentTypes)
  }

  static func startDirectory(for path: String?) -> URL {
    var isDirectory: ObjCBool = false

    if let path, path.hasPrefix("/"),
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
    {
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    return FileManager.default.homeDirectoryForCurrentUser
  }
}

/// Shows an open panel and returns what the user chose, in order. An empty list means the user
/// cancelled. The window is the one the panel hangs from as a sheet, and nil runs it as a modal.
public typealias OpenPicker =
  @MainActor (_ request: OpenPanelRequest, _ window: NSWindow?) async -> [URL]

/// The system's open panel. It chooses files and folders, and it treats a package as one file.
public enum SystemOpenPanel {
  @MainActor
  public static func pick(_ request: OpenPanelRequest, over window: NSWindow?) async -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = request.allowsMultipleSelection
    panel.treatsFilePackagesAsDirectories = false
    panel.directoryURL = request.directory

    if let types = request.contentTypes { panel.allowedContentTypes = types }

    let response: NSApplication.ModalResponse

    if let window {
      response = await panel.beginSheetModal(for: window)
    } else {
      response = panel.runModal()
    }

    return response == .OK ? panel.urls : []
  }
}
