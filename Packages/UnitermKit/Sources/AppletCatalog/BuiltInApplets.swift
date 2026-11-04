import AppletKit
import TerminalApplet

/// The applet types this build ships, with the content types each opens. A new applet type adds
/// its declaration here, beside the code that declares it. Tests read this list, and so does the
/// router.
public enum BuiltInApplets {
  public static let declarations: [AppletTypeDeclaration] = [
    TerminalApplet.typeDeclaration
  ]
}
