import AppKit
import AppletKit

#if DEBUG
  /// Speaker notes. A driver sets or clears them, and each change is an event.
  @MainActor
  public final class NotesFixture: FixtureApplet, AppletCommandHandling {
    public nonisolated static let typeID = "fixture-notes"

    public nonisolated static let schema = AppletCommandSchema(
      appletType: typeID, version: 1,
      commands: [
        AppletMessageSchema(
          name: "set-notes", summary: "Replaces the notes.",
          arguments: AppletObjectSchema(["text": .init(.string(maxBytes: 4096))]),
          example: .object(["text": .string("Mention the deadline.")])),
        AppletMessageSchema(name: "clear", summary: "Removes the notes."),
      ],
      events: [
        AppletMessageSchema(
          name: "notes-shown", summary: "The notes changed.",
          arguments: AppletObjectSchema(["length": .init(.integer(minimum: 0, maximum: 4096))])),
        AppletMessageSchema(name: "notes-acknowledged", summary: "The user pressed Done."),
      ])

    public private(set) var text = ""
    private var textLabel: NSTextField!

    public init() {
      super.init(typeID: Self.typeID, title: "Notes fixture", buttonTitle: "Done")
      configure()
    }

    public init(restoring description: AppletDescription) throws {
      let fields = try Self.object(of: description, type: Self.typeID)

      super.init(typeID: Self.typeID, title: "Notes fixture", buttonTitle: "Done")

      if case .string(let saved)? = fields["text"] { text = saved }

      configure()
    }

    private func configure() {
      textLabel = label("text")
      addButton()
      refresh()
    }

    public var commandSchema: AppletCommandSchema { Self.schema }

    public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError) -> JSONValue {
      switch command.name {
      case "set-notes":
        guard case .string(let value)? = command.arguments["text"] else {
          throw AppletCommandError(.badArgument, "the text is missing")
        }

        text = value

      case "clear":
        text = ""

      default:
        throw AppletCommandError(.unknownCommand, "the notes fixture has no \(command.name)")
      }

      refresh()
      events.emit("notes-shown", .object(["length": .number(Double(text.utf8.count))]))

      return .object(["length": .number(Double(text.utf8.count))])
    }

    override func userPressedButton() {
      events.emit("notes-acknowledged")
    }

    private func refresh() {
      textLabel.stringValue = text.isEmpty ? "No notes" : text
    }

    override var payload: JSONValue { .object(["text": .string(text)]) }
  }
#endif
