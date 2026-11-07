import AppletKit
import ImageViewerModel
import UniformTypeIdentifiers

extension ImageViewerApplet {
  /// The image viewer opens images as the owner and folders as an alternate, since the terminal is
  /// the default for a folder.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: ImageViewerDescription.typeID, displayName: "Image Viewer", symbolName: "photo",
    opens: [
      OpenedType("public.image", rank: .owner),
      OpenedType("public.folder", rank: .alternate),
    ])

  /// The image viewer's own commands. Open has no key, since Cmd-O belongs to the window's File >
  /// Open, which routes by type.
  ///
  /// The rest sit in a menu named for the viewer, and none of them has a key. A text-editing chord
  /// such as Cmd-Left would reach the menu before the palette's search field does, and the palette
  /// would close to run the command. The viewer's plain keys act only in the image view.
  ///
  /// The zoom commands sit in View with keys, as the terminal's and the map's do, since each
  /// applet's keys apply only while its pane has focus. Actual Size is the terminal's title, so one
  /// App Shortcuts remap moves both items. Zoom In and Zoom Out are the map's titles. Zoom to Fit
  /// takes Cmd-9, which the terminal holds for its last tab.
  ///
  /// Play or Pause Slideshow is one command, since a command has one title and the registry keeps
  /// no state for it. The status bar shows whether the slideshow plays.
  public static let commandSet = AppletCommandSet(
    typeID: ImageViewerDescription.typeID, menuTitle: "Image Viewer",
    commands: [
      .openSource(section: 1),
      .step(name: "next", title: "Next Image", .next, section: 0),
      .step(name: "previous", title: "Previous Image", .previous, section: 0),
      .step(name: "first", title: "First Image", .first, section: 0),
      .step(name: "last", title: "Last Image", .last, section: 0),
      .viewer(
        name: "play-pause", title: "Play or Pause Slideshow", section: 1,
        isAvailable: { $0.isPlaying || $0.canPlay }
      ) { $0.togglePlayback() },
      .viewer(name: "sort-by-name", title: "Sort by Name", section: 2) { $0.setSort(.name) },
      .viewer(name: "sort-by-date", title: "Sort by Date Modified", section: 2) {
        $0.setSort(.dateModified)
      },
      .viewer(name: "reload", title: "Reload Folder", section: 3) { $0.reloadFolder() },
      .zoom(name: "zoom-in", title: "Zoom In", key: KeyChord("+")) { $0.zoomIn() },
      .zoom(name: "zoom-out", title: "Zoom Out", key: KeyChord("-")) { $0.zoomOut() },
      .zoom(name: "actual-size", title: "Actual Size", key: KeyChord("0")) {
        $0.zoomToActualSize()
      },
      .zoom(name: "zoom-to-fit", title: "Zoom to Fit", key: KeyChord("9")) { $0.zoomToFit() },
    ])
}

extension AppletCommand {
  /// An image viewer command in the viewer's menu, with no key. It is off while the pane has no
  /// source.
  fileprivate static func viewer(
    name: String, title: String, section: Int,
    isAvailable: @escaping @MainActor (ImageViewerApplet) -> Bool = { _ in true },
    run: @escaping @MainActor (ImageViewerApplet) -> Void
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, home: .applet, section: section,
      isAvailable: { applet in
        guard let viewer = applet as? ImageViewerApplet else { return false }

        return viewer.hasSource && isAvailable(viewer)
      },
      run: { applet in
        guard let viewer = applet as? ImageViewerApplet else { return }

        run(viewer)
      })
  }

  /// A View menu command on the zoom. It is off while the pane shows nothing it can zoom.
  fileprivate static func zoom(
    name: String, title: String, key: KeyChord,
    run: @escaping @MainActor (ImageViewerApplet) -> Void
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .view, section: 3,
      isAvailable: { ($0 as? ImageViewerApplet)?.canZoom ?? false },
      run: { applet in
        guard let viewer = applet as? ImageViewerApplet else { return }

        run(viewer)
      })
  }

  fileprivate static func step(
    name: String, title: String, _ step: ListingStep, section: Int
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, home: .applet, section: section,
      isAvailable: { ($0 as? ImageViewerApplet)?.canStep(step) ?? false },
      run: { ($0 as? ImageViewerApplet)?.step(step) })
  }
}
