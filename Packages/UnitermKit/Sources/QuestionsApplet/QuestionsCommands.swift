import AppKit
import AppletKit

extension QuestionsApplet {
  /// The Questions pane opens no file, and the user cannot open one by hand, since a program
  /// opens it. It takes no remote control.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: QuestionsDescription.typeID, displayName: "Questions",
    symbolName: "questionmark.bubble",
    opens: [])

  /// The tab commands carry the terminal's and the browser's titles, so a user's App Shortcuts
  /// remap of an item matches every tabbed applet. There is no New Tab, since only a program's
  /// form opens a tab.
  public static let commandSet = AppletCommandSet(
    typeID: QuestionsDescription.typeID, menuTitle: "Questions", commands: tabCommands())

  private static func tabCommands() -> [AppletCommand] {
    var commands = [
      AppletCommand(
        name: "next-tab", title: "Select Next Tab", key: KeyChord("\t", .control),
        home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? QuestionsApplet)?.step(by: 1) }),
      AppletCommand(
        name: "previous-tab", title: "Select Previous Tab",
        key: KeyChord("\t", [.control, .shift]), home: .window, section: 1,
        isAvailable: hasSeveralTabs,
        run: { ($0 as? QuestionsApplet)?.step(by: -1) }),
    ]

    for number in 1...9 {
      commands.append(
        AppletCommand(
          name: number == 9 ? "last-tab" : "tab-\(number)",
          title: number == 9 ? "Select Last Tab" : "Select Tab \(number)",
          key: KeyChord(String(number)), home: .window, section: 1, listedInPalette: false,
          isAvailable: hasSeveralTabs,
          run: { ($0 as? QuestionsApplet)?.selectTab(number: number) }))
    }

    return commands
  }

  private static func hasSeveralTabs(_ applet: any Applet) -> Bool {
    ((applet as? QuestionsApplet)?.tabCount ?? 0) > 1
  }
}
