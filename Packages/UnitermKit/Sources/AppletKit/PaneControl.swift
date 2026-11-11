import Foundation

/// Whether programs other than the user may address a pane's applet. The host holds each pane's
/// mode, keyed by window and pane. An applet never sets it. Only a local user action enables a
/// pane, and a program can never enable one.
public enum PaneAccessMode: String, Sendable, Hashable, CaseIterable {
  /// No other program may address the applet. Host lifecycle events and the user's own actions
  /// still reach it. Every new user pane starts here.
  case disconnected

  /// Programs the trust rules allow may drive the applet. The pane shows a marker.
  case remoteControlled = "remote-controlled"
}

/// The program attached to a pane as its driver, apart from its access mode. A driver's channel
/// is explicitly attached, so a disconnected pane keeps it.
public enum PaneDriverKind: String, Sendable, Hashable, CaseIterable {
  case none

  /// A program whose stdin takes the applet's events and whose stdout drives the applet.
  case exec
}

/// One access mode with one driver. An applet type declares the combinations it supports, and a
/// combination it does not declare is refused before a pane is created or a driver launches.
public struct ControlCombination: Sendable, Hashable, CustomStringConvertible {
  public let access: PaneAccessMode
  public let driver: PaneDriverKind

  public init(access: PaneAccessMode, driver: PaneDriverKind) {
    self.access = access
    self.driver = driver
  }

  /// The combination every applet type supports, whether or not it declares it.
  public static let disconnected = ControlCombination(access: .disconnected, driver: .none)

  public static let remoteControlled = ControlCombination(access: .remoteControlled, driver: .none)

  public var description: String {
    driver == .none ? access.rawValue : "\(access.rawValue) with an \(driver.rawValue) driver"
  }
}

/// A pane's control state as its applet sees it. The window pushes it to the applet before the
/// applet starts and on every change, so the applet never reads it from anywhere else.
///
/// The generation changes whenever the pane's authority changes: a mode change, a revoked
/// controller, or a lost owner. A permission the applet asked for under one generation is stale
/// under the next.
public struct PaneControl: Sendable, Equatable {
  public var access: PaneAccessMode
  public var driver: PaneDriverKind
  public var generation: UInt64

  public init(access: PaneAccessMode, driver: PaneDriverKind, generation: UInt64) {
    self.access = access
    self.driver = driver
    self.generation = generation
  }

  /// A pane is controlled when other programs may drive it or a driver is attached. Its
  /// programmatic clipboard use then needs the user's explicit permission.
  public var isControlled: Bool {
    access == .remoteControlled || driver != .none
  }

  public static let disconnected = PaneControl(access: .disconnected, driver: .none, generation: 0)
}
