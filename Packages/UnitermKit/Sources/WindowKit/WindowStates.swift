import Foundation

/// A kind of state that belongs to the window, not to the focused pane. The cases are in the order
/// the status bar shows them, and that order is fixed.
///
/// The window shows one slot for each active kind, after the message area and before the focused
/// applet's segments. A feature that owns one of these conditions fills its kind when the
/// condition starts and clears it when the condition ends.
public enum WindowStateKind: Int, CaseIterable, Comparable, Sendable {
  /// Another instance owns the layout, so this window's panes are not saved.
  case layoutNotSaved

  /// A program asked for permissions that the user has not answered.
  case pendingPermissions

  /// Work that outlives a closed pane is still running, as the applet lifecycle requires to be
  /// visible.
  case survivingWork

  public static func < (lhs: WindowStateKind, rhs: WindowStateKind) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The compact symbol the slot shows.
  var symbolName: String {
    switch self {
    case .layoutNotSaved: return "externaldrive.badge.xmark"
    case .pendingPermissions: return "lock.shield"
    case .survivingWork: return "hourglass"
    }
  }

  /// The name of the kind, for the accessibility identifier.
  var identifier: String {
    switch self {
    case .layoutNotSaved: return "layout-not-saved"
    case .pendingPermissions: return "pending-permissions"
    case .survivingWork: return "surviving-work"
    }
  }
}

/// The window states that hold now, each with the full sentence that its slot shows as a tooltip
/// and reads aloud.
///
/// This is runtime state of the app. It never enters the layout file.
public struct WindowStates: Sendable, Equatable {
  private var texts: [WindowStateKind: String] = [:]

  public init() {}

  /// The kinds that hold, in the fixed order, with their sentences.
  public var active: [(kind: WindowStateKind, text: String)] {
    WindowStateKind.allCases.compactMap { kind in texts[kind].map { (kind, $0) } }
  }

  public var isEmpty: Bool { texts.isEmpty }

  /// Marks `kind` as holding, described by `text`. A second call replaces the sentence.
  public mutating func set(_ kind: WindowStateKind, text: String) {
    texts[kind] = text
  }

  public mutating func clear(_ kind: WindowStateKind) {
    texts[kind] = nil
  }

  public func text(of kind: WindowStateKind) -> String? {
    texts[kind]
  }
}
