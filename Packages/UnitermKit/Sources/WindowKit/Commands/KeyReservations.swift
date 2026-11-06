import AppKit
import AppletKit

/// A key an applet command asked for and could not have.
struct KeyConflict: Equatable {
  enum Reason: Equatable {
    /// uniterm reserves the key.
    case reserved

    /// Another command of the same applet asked for it too, so both lose it.
    case sameApplet
  }

  let typeID: String
  let commandID: CommandID
  let commandTitle: String
  let key: KeyChord
  let reason: Reason
}

/// The rules for which applet command gets which key.
///
/// uniterm reserves its own window command keys, the fixed Edit keys, and the keys AppKit adds to
/// the menus. A command that asks for a reserved key registers without it. Two commands of one
/// applet on one key both lose it. Keys are compared in their canonical form, so Cmd-} and
/// Cmd-Shift-] are the same key.
enum KeyReservations {
  /// The Edit menu's keys. They are fixed whatever the menu holds.
  static let editKeys: Set<KeyChord> = [
    KeyChord("x"), KeyChord("c"), KeyChord("v"), KeyChord("a"), KeyChord("z"),
    KeyChord("z", [.command, .shift]),
  ]

  struct Resolution {
    var keys: [CommandID: KeyChord]
    var conflicts: [KeyConflict]
  }

  @MainActor
  static func resolve(sets: [AppletCommandSet], reserved: Set<KeyChord>) -> Resolution {
    var resolution = Resolution(keys: [:], conflicts: [])
    let blocked = reserved.union(editKeys)

    for set in sets {
      var holders: [KeyChord: [AppletCommand]] = [:]

      for command in set.commands {
        if let key = command.key {
          holders[key, default: []].append(command)
        }
      }

      for command in set.commands {
        guard let key = command.key else { continue }

        let id = CommandRegistry.commandID(typeID: set.typeID, name: command.name)

        if blocked.contains(key) {
          resolution.conflicts.append(
            KeyConflict(
              typeID: set.typeID, commandID: id, commandTitle: command.title, key: key,
              reason: .reserved))
        } else if holders[key, default: []].count > 1 {
          resolution.conflicts.append(
            KeyConflict(
              typeID: set.typeID, commandID: id, commandTitle: command.title, key: key,
              reason: .sameApplet))
        } else {
          resolution.keys[id] = key
        }
      }
    }

    return resolution
  }

  /// The most drops one applet lists in the message. A longer list ends with a count, so one
  /// remap of a shared key such as Cmd-1 stays readable.
  static let listedDrops = 3

  /// One message for every applet that lost a key. It names each applet, its commands, and their
  /// keys, and it says what to do next.
  static func warning(for groups: [(menuTitle: String, conflicts: [KeyConflict])]) -> String {
    let parts = groups.map { group -> String in
      let listed = group.conflicts.prefix(listedDrops).map {
        describe($0, menuTitle: group.menuTitle)
      }
      let rest = group.conflicts.count - listed.count
      let more = rest > 0 ? ["and \(rest) more lose their keys too"] : []

      return "\(group.menuTitle): " + (listed + more).joined(separator: "; ")
    }

    return parts.joined(separator: ". ")
      + ". The commands still work from the menu and the command palette. To give one a key, "
      + "choose it in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts."
  }

  private static func describe(_ conflict: KeyConflict, menuTitle: String) -> String {
    let key = KeyEquivalentText.spell(key: conflict.key.key, modifiers: conflict.key.modifiers)
    let spelled = key ?? conflict.key.key
    let why =
      conflict.reason == .reserved ? "uniterm uses it" : "another \(menuTitle) command asks for it"

    return "\u{201C}\(conflict.commandTitle)\u{201D} has no key, because \(why) (\(spelled))"
  }
}
