import Foundation

/// A power a command needs beyond the caller's control of the pane. Shared dispatch refuses a
/// command whose power the caller does not hold, before the applet sees it.
///
/// The raw value is the name of the controller permission that grants the power. AppletKit knows
/// no controller types, so the window maps the caller's held permissions to these by name.
public enum AppletCommandPermission: String, Sendable, Hashable, CaseIterable {
  /// Opening browser tabs and moving them. That is network access signed in as the user.
  case browserNavigation = "browser-navigation"

  /// Reading the addresses and titles of browser tabs.
  case browserRead = "browser-read"
}

/// Names one caller's grant over a pane, and nothing else about the caller. An applet that keeps
/// state for a caller keys it by this value and drops the state when the grant ends. Two grants
/// never share a value, so a state kept under one never serves another.
public struct AppletCaller: Sendable, Hashable, CustomStringConvertible {
  public let grant: String

  public init(grant: String) {
    self.grant = grant
  }

  public var description: String { grant }
}

/// What a command's caller brings besides what it reads: which grant it acts under, and the
/// powers that grant holds right now. The dispatcher asks again as it delivers the command.
public struct CommandCaller: Sendable, Equatable {
  public let identity: AppletCaller?
  public let permissions: Set<AppletCommandPermission>

  public init(identity: AppletCaller?, permissions: Set<AppletCommandPermission> = []) {
    self.identity = identity
    self.permissions = permissions
  }

  /// A caller with no grant and no power.
  public static let none = CommandCaller(identity: nil)
}

extension AppletTabID {
  /// The ID as a reply spells it. `init(reply:)` reads it back.
  public var replyText: String { description }

  public init?(reply text: String) {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)

    guard parts.count == 2, let epoch = UInt64(parts[0], radix: 16), let serial = UInt64(parts[1])
    else { return nil }

    self.init(epoch: epoch, serial: serial)
  }
}
