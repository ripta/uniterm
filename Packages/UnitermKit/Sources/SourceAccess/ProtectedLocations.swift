import Foundation

/// The places macOS guards with a privacy prompt or a mount, and that a read scope never covers
/// by containing them. This is the one list. A scope names a protected location to cover it.
///
/// A scope of `~` reaches everything under it except these. A request for `~/Documents/x` is not
/// covered by an approved `~`, so it asks. Nothing outside a scope is ever opened, so a path that
/// only a protected location holds cannot raise a prompt under uniterm's name.
public struct ProtectedLocations: Sendable, Equatable {
  /// One protected place and how a person calls it.
  public struct Entry: Sendable, Equatable {
    /// The absolute path, or nil for a place found by name, such as a Photos library.
    public let path: String?
    public let label: String
  }

  /// The suffix of a Photos library package, wherever it sits.
  public static let photosLibrarySuffix = ".photoslibrary"

  public private(set) var home: String
  public private(set) var entries: [Entry]

  /// The protected places under `home`, and the volumes and mount points outside it. `/net` and
  /// `/home` are automount points, which `/Network` and `/Volumes` stand beside.
  public init(home: String) {
    self.home = home

    entries = [
      Entry(path: home + "/Documents", label: "Documents"),
      Entry(path: home + "/Desktop", label: "Desktop"),
      Entry(path: home + "/Downloads", label: "Downloads"),
      Entry(path: home + "/Library/Mobile Documents", label: "iCloud Drive"),
      Entry(path: home + "/Library/Containers", label: "other apps' containers"),
      Entry(path: home + "/Library/Group Containers", label: "other apps' containers"),
      Entry(path: "/Volumes", label: "removable and network volumes"),
      Entry(path: "/Network", label: "removable and network volumes"),
      Entry(path: "/net", label: "removable and network volumes"),
      Entry(path: "/home", label: "removable and network volumes"),
      Entry(path: nil, label: "the Photos library"),
    ]
  }

  /// The same places, and the places under the home folder with its links resolved. A walk works
  /// with resolved paths, so a home folder reached through a link must be named in both forms.
  public func resolvingLinks() -> ProtectedLocations {
    guard let pointer = realpath(home, nil) else { return self }

    defer { free(pointer) }

    let resolved = String(cString: pointer)

    guard resolved != home else { return self }

    var result = ProtectedLocations(home: resolved)

    result.home = home
    result.entries = entries + result.entries.filter { $0.path?.hasPrefix(resolved + "/") == true }

    return result
  }

  /// The places of the current user.
  public static var current: ProtectedLocations {
    ProtectedLocations(home: NSHomeDirectory())
  }

  /// The shortest protected place that holds `path`, as the names leading to it, when that place
  /// lies strictly inside `directory`. A scope directory leaves such a place out. A place that is
  /// `directory` or holds it is not strictly inside, so a scope naming a protected place covers
  /// it.
  public func place(
    holding path: [String], strictlyInside directory: [String]
  ) -> [String]? {
    // The fold is applied whatever the volume's own rule. A case-sensitive scope volume can still
    // hold a name that another volume, or a later rename, would equate with a protected place.
    let folding = PathComparison.alwaysFolding

    guard path.count > directory.count, folding.isInside(path, directory) else { return nil }

    var shortest: [String]?

    for entry in entries {
      guard let text = entry.path, let names = PathComparison.plainComponents(of: text),
        names.count > directory.count, folding.isInside(names, directory),
        folding.isInside(path, names)
      else { continue }

      if names.count < (shortest?.count ?? Int.max) { shortest = names }
    }

    for index in directory.count..<path.count {
      guard PathComparison.folded(path[index]).hasSuffix(Self.photosLibrarySuffix) else {
        continue
      }

      let names = Array(path[0...index])

      if names.count < (shortest?.count ?? Int.max) { shortest = names }

      break
    }

    return shortest
  }

  /// Every protected place a scope directory lies in or names, by label. These are the places the
  /// directory covers by being one of them, or by sitting inside one.
  public func labels(lyingIn directory: [String], using comparison: PathComparison) -> [String] {
    var found: [String] = []

    for entry in entries {
      guard let text = entry.path, let names = PathComparison.plainComponents(of: text),
        comparison.isInside(directory, names)
      else { continue }

      found.append(entry.label)
    }

    if directory.contains(where: { PathComparison.folded($0).hasSuffix(Self.photosLibrarySuffix) })
    {
      found.append("the Photos library")
    }

    return found
  }

  /// Every protected place a scope directory contains and so leaves out, by label.
  public func labels(leftOutOf directory: [String], using comparison: PathComparison) -> [String] {
    var found: [String] = []

    for entry in entries {
      guard let text = entry.path, let names = PathComparison.plainComponents(of: text),
        names.count > directory.count, comparison.isInside(names, directory)
      else { continue }

      found.append(entry.label)
    }

    // A Photos library is a package that usually sits in Pictures, and it can sit anywhere below a
    // folder. A folder that holds Pictures is where one is likely to be left out.
    if let pictures = PathComparison.plainComponents(of: home + "/Pictures"),
      comparison.isInside(pictures, directory)
    {
      found.append("the Photos library")
    }

    return found
  }
}
