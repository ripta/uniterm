import Foundation

/// How strongly an applet type claims a content type. The rank is uniterm's own routing. It never
/// becomes a Launch Services rank.
public enum OpenRank: String, Sendable, Equatable, Hashable {
  /// The applet is the default for the type.
  case owner

  /// The applet can open the type and is not the default.
  case alternate
}

/// One content type an applet type opens, named by its type identifier, such as `public.folder`.
public struct OpenedType: Sendable, Equatable, Hashable {
  public let identifier: String
  public let rank: OpenRank

  public init(_ identifier: String, rank: OpenRank) {
    self.identifier = identifier
    self.rank = rank
  }
}

/// What an applet type declares about the files it opens. It is plain data, so the router and the
/// tests can read every declaration without starting an applet.
///
/// An applet declares `public.folder` for a folder and never `public.directory`, so a package such
/// as an app bundle is not a folder to it. The factory that turns a file into an applet is kept
/// apart, since building one can need the host's engine.
public struct AppletTypeDeclaration: Sendable, Equatable {
  /// The same identifier the applet's description carries.
  public let typeID: String

  /// What a chooser calls the applet.
  public let displayName: String

  /// The SF Symbol that stands for the applet beside its name, such as in a palette row.
  public let symbolName: String

  public let opens: [OpenedType]

  /// The access-mode and driver combinations the type declares. A type that declares none
  /// supports only disconnected access with no driver. Read `supportedControl` for the set that
  /// applies.
  public let controlSupport: Set<ControlCombination>

  public init(
    typeID: String, displayName: String, symbolName: String, opens: [OpenedType],
    controlSupport: Set<ControlCombination> = []
  ) {
    self.typeID = typeID
    self.displayName = displayName
    self.symbolName = symbolName
    self.opens = opens
    self.controlSupport = controlSupport
  }

  /// The combinations a pane of this type may use. Disconnected with no driver is always among
  /// them, since a pane must be able to refuse every program.
  public var supportedControl: Set<ControlCombination> {
    controlSupport.union([.disconnected])
  }

  /// The combinations a pane of `typeID` may use. A type with no declaration, such as the
  /// launcher or a placeholder, gets the default.
  public static func supportedControl(
    forType typeID: String, in declarations: [AppletTypeDeclaration]
  ) -> Set<ControlCombination> {
    declarations.first { $0.typeID == typeID }?.supportedControl ?? [.disconnected]
  }
}

/// Makes an applet that opens one file or folder. This is the entry point an applet's own open
/// panel and drop use. The start directory is explicit and absolute. It comes from the request,
/// and the factory never reads it from another pane. The factory throws when it cannot open the
/// file. An applet that also adopts `SourceReplacing` implements `replaceSource` through the same
/// code, so a pane-local Open and a routed open take the same path.
public typealias AppletSourceFactory =
  @MainActor (_ file: URL, _ startDirectory: String) throws ->
  any Applet
