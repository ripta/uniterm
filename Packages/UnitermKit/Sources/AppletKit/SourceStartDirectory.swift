import Foundation

/// The folder an applet opened from a file or folder starts in. The router and the pane-local Open
/// both use this one rule, so a source starts in the same place however it arrived.
///
/// A folder starts in itself, and a file in its own folder. The path stays as the request named it,
/// so a symlink to a folder starts at the link. Only the kind comes from the target.
public enum SourceStartDirectory {
  public static func of(_ url: URL, isFolder: Bool) -> String {
    isFolder ? url.path : url.deletingLastPathComponent().path
  }

  /// The start directory for a path whose kind is not known yet. `stat` follows a symlink, as the
  /// router's classification does, and never opens the path.
  public static func of(_ url: URL) -> String {
    var info = stat()
    let isFolder = stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR

    return of(url, isFolder: isFolder)
  }
}
