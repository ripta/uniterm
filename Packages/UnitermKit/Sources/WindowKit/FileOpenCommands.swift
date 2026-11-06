import AppKit
import AppletKit
import FileRouting
import Foundation

/// The File > Open and File > Open With commands. Each shows an open panel and hands the chosen
/// files to the router.
///
/// A file the user picks in the panel is the user's act and needs no grant. The panel starts in the
/// directory the anchor pane reports, or the home folder, and never in the folder AppKit last used.
/// It hangs from the anchor's window as a sheet, or runs as a modal when there is no window. The
/// router runs after the panel is gone, since a window with a sheet attached has no room for a
/// pane.
@MainActor
public final class FileOpenCommands {
  private let opener: RoutedOpener
  private let picker: OpenPicker
  private let present: OpenWithPresenter
  private let sleeper: SheetSleeper

  /// Waits one poll interval while a sheet detaches. Tests inject their own.
  public typealias SheetSleeper = @MainActor () async -> Void

  /// How many times a sheet gets a chance to detach.
  static let sheetPolls = 25

  public static let sheetPoll: SheetSleeper = {
    try? await Task.sleep(for: .milliseconds(20))
  }

  public init(
    opener: RoutedOpener, picker: @escaping OpenPicker = SystemOpenPanel.pick,
    present: @escaping OpenWithPresenter = FileOpenCommands.presentChooser,
    sleeper: @escaping SheetSleeper = FileOpenCommands.sheetPoll
  ) {
    self.opener = opener
    self.picker = picker
    self.present = present
    self.sleeper = sleeper
  }

  public static func presentChooser(
    _ model: OpenWithModel, over window: NSWindow?
  ) async -> OpenWithOutcome {
    await OpenWithChooser(model: model).present(in: window)
  }

  /// Asks for files and folders, and opens each as the router decides. A single file opens beside
  /// the anchor pane. Several follow the batch rule, which the router enforces.
  public func open(from anchor: RouteAnchor?) async {
    let files = await pick(from: anchor, allowsMultipleSelection: true).filter(\.isFileURL)

    guard !files.isEmpty else { return }

    await opener.open(files, from: anchor)
  }

  /// Asks for one file or folder, then shows the Open With chooser for it.
  public func openWith(from anchor: RouteAnchor?) async {
    guard let file = await pick(from: anchor, allowsMultipleSelection: false).first,
      file.isFileURL
    else { return }

    await opener.openWithChoice(file, from: anchor) { [present] model, window in
      let outcome = await present(model, window)
      await waitForSheetToDetach(from: window)
      return outcome
    }
  }

  /// Gives a sheet that just answered time to leave its window. The router treats a window with a
  /// sheet attached as full, and a pane placed then would land in a new window. The wait is bounded,
  /// so a sheet that stays still gets the router's answer.
  private func waitForSheetToDetach(from window: NSWindow?) async {
    var polls = 0

    while let window, window.attachedSheet != nil, polls < Self.sheetPolls {
      polls += 1
      await sleeper()
    }
  }

  private func pick(from anchor: RouteAnchor?, allowsMultipleSelection: Bool) async -> [URL] {
    let directory = anchor.flatMap { $0.controller.directory(of: $0.pane) }

    let request = OpenPanelRequest(
      startingIn: directory, allowsMultipleSelection: allowsMultipleSelection)

    let chosen = await picker(request, anchor?.controller.window)
    await waitForSheetToDetach(from: anchor?.controller.window)
    return chosen
  }
}
