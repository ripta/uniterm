import AppKit

/// An applet that shows one source and can swap it for another. A viewer adopts this to get the
/// pane-local Open command.
///
/// `replaceSource` and the applet type's `AppletSourceFactory` are the two faces of one
/// source-taking function. The factory makes an applet that opens the source, and `replaceSource`
/// swaps the source of a running one. A viewer implements both through the same code, so the
/// router, a drop, and this command all reach one path. The start directory is explicit and absolute. It comes from the
/// chosen file, and the applet never reads it from another pane.
@MainActor
public protocol SourceReplacing: Applet {
  func replaceSource(with file: URL, startDirectory: String) throws
}

extension AppletCommand {
  /// The pane-local "Open..." that a viewer's command set declares. It has no key, since Cmd-O
  /// belongs to the window's File > Open, which routes by type. A user can remap a key to it.
  ///
  /// It replaces the source of the pane the command is aimed at. Choosing the file in the panel is
  /// the user's act. The applet gets that one file and nothing more.
  public static func openSource(
    section: Int = 0, picker: @escaping OpenPicker = SystemOpenPanel.pick
  ) -> AppletCommand {
    AppletCommand(
      name: openSourceName, title: "Open\u{2026}", home: .file, section: section,
      isAvailable: { $0 is any SourceReplacing },
      run: { applet in
        Task { @MainActor [weak applet] in
          guard let applet else { return }

          await SourceOpening.open(applet, picker: picker)
        }
      })
  }

  /// The command's name within its applet type.
  public static let openSourceName = "open"
}

/// The work behind the pane-local Open command.
public enum SourceOpening {
  /// Asks for one file or folder and hands it to the applet. A failure goes to the pane's status
  /// bar, and the applet keeps the source it had.
  @MainActor
  public static func open(_ applet: any Applet, picker: OpenPicker) async {
    guard let target = applet as? any SourceReplacing else { return }

    let request = OpenPanelRequest(
      startingIn: applet.currentDirectory, allowsMultipleSelection: false)

    guard let file = await picker(request, applet.view.window).first else { return }

    do {
      try target.replaceSource(with: file, startDirectory: SourceStartDirectory.of(file))
    } catch {
      target.host?.applet(
        target, post: .error,
        text:
          "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: "
          + error.localizedDescription)
    }
  }
}
