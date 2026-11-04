import AppletKit
import Foundation

/// The saved "Open With" choices: one defaults key that holds a dictionary from an exact type
/// identifier to an applet type ID.
///
/// A read never writes. Each entry decodes on its own, so a corrupt or unknown entry is left out of
/// routing and stays on disk exactly as it was. An older build ignores the key and keeps it. Only
/// the user's chooser changes an entry, and the writers below are file-private to this file, where
/// `OpenWithModel` is the only caller. No controller, script, or other module can reach them.
public final class SavedChoiceStore: @unchecked Sendable {
  public static let defaultsKey = "openWithChoices"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The entries that decode. A stored value that is not a dictionary reads as empty.
  public func choices() -> [String: String] {
    guard let stored = defaults.dictionary(forKey: Self.defaultsKey) else { return [:] }

    var decoded: [String: String] = [:]

    for (type, applet) in stored {
      if !type.isEmpty, let applet = applet as? String, !applet.isEmpty {
        decoded[type] = applet
      }
    }

    return decoded
  }

  /// Sets one entry and leaves every other entry, valid or not, as stored.
  fileprivate func save(_ appletTypeID: String, forType type: String) {
    var stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
    stored[type] = appletTypeID
    defaults.set(stored, forKey: Self.defaultsKey)
  }

  /// Removes one entry and leaves every other entry as stored.
  fileprivate func clear(type: String) {
    guard var stored = defaults.dictionary(forKey: Self.defaultsKey), stored[type] != nil else {
      return
    }

    stored[type] = nil
    defaults.set(stored, forKey: Self.defaultsKey)
  }
}

/// What the "Open With" chooser holds for one file: the applets that declare its type, the one
/// picked, and whether to remember the pick for the file's exact type.
@MainActor
public final class OpenWithModel {
  public let file: URL
  public let type: String

  /// Every applet that declares the file's type. The likeliest comes first.
  public let candidates: [AppletTypeDeclaration]

  /// The applet type ID the user picked.
  public var selection: String

  /// Whether the pick is saved for the file's exact type.
  public var alwaysUse = false

  /// The applet type ID saved for the exact type, when it is one of the candidates.
  public private(set) var savedAppletTypeID: String?

  private let store: SavedChoiceStore

  /// A dynamic type names one extension and not a kind of file, so a choice saved for it would
  /// match nothing else and clutter the store.
  public var canSaveChoice: Bool { !type.hasPrefix("dyn.") }

  public init?(
    file: URL, type: String, candidates: [AppletTypeDeclaration], store: SavedChoiceStore
  ) {
    guard let first = candidates.first else { return nil }

    self.file = file
    self.type = type
    self.candidates = candidates
    self.store = store

    let saved = store.choices()[type]
    savedAppletTypeID = candidates.first { $0.typeID == saved }?.typeID
    selection = savedAppletTypeID ?? first.typeID
  }

  /// True when any choice is stored for the exact type, even one that names an applet this build
  /// lacks. The chooser offers to clear it.
  public var hasStoredChoice: Bool { store.choices()[type] != nil }

  /// Settles the pick. Saves it first when the user asked for that, and returns the applet type ID
  /// to open the file with.
  public func confirm() -> String {
    if alwaysUse, canSaveChoice {
      store.save(selection, forType: type)
      savedAppletTypeID = selection
    }

    return selection
  }

  /// Forgets the saved choice for the exact type. The next open follows the rank again.
  public func clearSavedChoice() {
    store.clear(type: type)
    savedAppletTypeID = nil
  }
}
