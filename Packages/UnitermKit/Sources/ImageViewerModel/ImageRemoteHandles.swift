import AppletKit
import Foundation

/// Why a show, a step, or a zoom did not finish. A code is a fixed word. It never carries a file
/// name or a path, since the reply that holds it crosses to a program.
public enum ImageRemoteFailure: String, Sendable, Equatable, CaseIterable {
  /// The source could not be found, opened, or read. This is also what a caller outside the
  /// pane's scope is told for every cause.
  case unreadable

  /// The file is not a type the viewer shows.
  case notAnImage = "not-an-image"

  /// The folder holds no image.
  case noImages = "no-images"

  /// The decoder does not support the image's format.
  case unsupported

  /// The image is past a size, memory, or time limit.
  case limit

  /// The decoder stopped, hung, or sent something uniterm refused.
  case decoderFailed = "decoder-failed"

  /// The zoom needs more than the helper cap, the app-wide helper budget, or the bitmap budget
  /// allows.
  case zoomLimit = "zoom-limit"
}

/// What the pane shows once an image settles, as a controller or a driver may be told.
///
/// The report holds the real path of the image's own descriptor and the path of the source it came
/// from. A reply is built from it only after the reader's scope holds both, so a symlink in an
/// in-scope folder whose target lies outside the scope gives a reader nothing.
public struct ShownReport: Equatable, Sendable {
  /// The image's file name, which settles a step that waited for that image. It never leaves the
  /// pane.
  public var name: String

  /// The real path of the image's descriptor.
  public var path: String

  /// The path of the file or folder the pane was opened on, or nil for none.
  public var source: String?

  /// The image's place in the listing, counted from zero.
  public var index: Int

  /// The images listed so far.
  public var count: Int

  /// True while the folder is still being listed, so the count and the order are provisional.
  public var partial: Bool

  public init(
    name: String, path: String, source: String?, index: Int, count: Int, partial: Bool
  ) {
    self.name = name
    self.path = path
    self.source = source
    self.index = index
    self.count = count
    self.partial = partial
  }

  /// The fields a reader may see. A reader whose scope does not hold the source and the image sees
  /// only that the image is outside it. The path, the index, and the count all say something about
  /// what the folder holds.
  public func fields(mayShow: (String?) -> Bool) -> [String: JSONValue] {
    guard mayShow(source), mayShow(path) else { return ["outside-scope": .bool(true)] }

    return [
      "outside-scope": .bool(false), "path": .string(path), "index": .number(Double(index)),
      "count": .number(Double(count)), "partial": .bool(partial),
    ]
  }
}

/// What a zoom command ended with. The scale is a multiple of actual size.
///
/// At fit the scale follows from the pane's size and the image's, so it says something about the
/// image. A reader that may not see the image is told only that the zoom ended. `source` and `path`
/// are the pane's source and the image's real path, which settle that.
public struct ZoomReport: Equatable, Sendable {
  public var isFit: Bool
  public var scale: Double
  public var source: String?
  public var path: String?

  public init(isFit: Bool, scale: Double, source: String? = nil, path: String? = nil) {
    self.isFit = isFit
    self.scale = scale
    self.source = source
    self.path = path
  }
}

/// How one command's effect ended.
public enum ImageRemoteOutcome: Equatable, Sendable {
  case shown(ShownReport)
  case zoomed(ZoomReport)

  /// `source` is the source the failure came from, and `path` the real path of the image that
  /// failed. A reader whose scope does not hold both is told the failure was unreadable, whatever
  /// the cause, and so is one when the image's own path is not known.
  case failed(ImageRemoteFailure, source: String?, path: String?)

  /// A newer command or load took the place of this one before it finished.
  case superseded
}

/// The results the pane keeps for the commands that changed it.
///
/// A command with an effect answers at once with a handle, and its result waits under that handle
/// for `wait`. The table holds the newest results. When it is full, the oldest finished one is
/// dropped. A handle still running is never dropped, and a new command of a kind replaces the
/// running one of its group, so running handles stay few.
public struct ImageHandleTable: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case show, step, zoom

    /// A show and a step both end when an image settles, so a newer one of either replaces the
    /// other. A zoom ends on its own.
    public var isNavigation: Bool { self != .zoom }
  }

  public struct Entry: Sendable, Equatable {
    public let id: Int
    public let kind: Kind

    /// The name of the image a step waits for, or nil when any image that settles will do.
    public let wanted: String?
    public var outcome: ImageRemoteOutcome?

    public var isSettled: Bool { outcome != nil }
  }

  public static let capacity = 32

  public private(set) var entries: [Entry] = []

  private var nextID = 1

  public init() {}

  public var hasRoom: Bool {
    entries.count < Self.capacity || entries.contains { $0.isSettled }
  }

  /// Makes a handle. Returns nil when the table is full of handles still running.
  public mutating func open(_ kind: Kind, wanted: String? = nil) -> Int? {
    if entries.count >= Self.capacity {
      guard let oldest = entries.firstIndex(where: { $0.isSettled }) else { return nil }

      entries.remove(at: oldest)
    }

    let id = nextID

    nextID += 1
    entries.append(Entry(id: id, kind: kind, wanted: wanted, outcome: nil))

    return id
  }

  public func entry(_ id: Int) -> Entry? {
    entries.first { $0.id == id }
  }

  /// Every handle still running, oldest first.
  public var running: [Entry] {
    entries.filter { !$0.isSettled }
  }

  /// Records how a handle ended. Returns false when it is unknown or already ended.
  @discardableResult
  public mutating func settle(_ id: Int, _ outcome: ImageRemoteOutcome) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isSettled
    else { return false }

    entries[index].outcome = outcome

    return true
  }

  /// What `wait` answers for a handle. A handle still running answers `pending`.
  ///
  /// `mayShow` says whether the reader may be told about a path. A reader that may not is told
  /// that a shown image is outside its scope, and every failure reads as `unreadable`, so it
  /// cannot tell a missing file from an unsupported one.
  public static func reply(for entry: Entry, mayShow: (String?) -> Bool) -> JSONValue {
    var fields: [String: JSONValue] = [:]

    switch entry.outcome {
    case nil:
      fields["state"] = .string("pending")

    case .shown(let report)?:
      fields = report.fields(mayShow: mayShow)
      fields["state"] = .string("shown")

    case .zoomed(let report)?:
      fields["state"] = .string("done")

      if shows(source: report.source, path: report.path, mayShow: mayShow) {
        fields["fit"] = .bool(report.isFit)
        fields["scale"] = .number(report.scale)
      }

    case .failed(let failure, let source, let path)?:
      fields["state"] = .string("failed")
      fields["code"] = .string(
        shows(source: source, path: path, mayShow: mayShow)
          ? failure.rawValue : ImageRemoteFailure.unreadable.rawValue)

    case .superseded?:
      fields["state"] = .string("superseded")
    }

    return .object(fields)
  }

  private static func shows(
    source: String?, path: String?, mayShow: (String?) -> Bool
  ) -> Bool {
    guard mayShow(source), let path else { return false }

    return mayShow(path)
  }

  /// The reply of a handle that is still running, for a wait that ran out of time.
  public static let pendingReply: JSONValue = .object(["state": .string("pending")])
}

extension SourceLoadFailure {
  /// The word a reply carries for this failure.
  public var remoteCode: ImageRemoteFailure {
    switch self {
    case .notAnImage: return .notAnImage
    case .noImages: return .noImages
    case .access, .kindChanged: return .unreadable
    }
  }
}
