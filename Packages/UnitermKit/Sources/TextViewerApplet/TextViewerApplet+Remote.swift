import AppKit
import AppletKit
import PDFKit
import SourceAccess
import TextViewerModel

/// The viewer's side of the applet command hook. Shared dispatch has already checked the
/// controller's authority, the schema version, and every argument by the time `perform` runs.
extension TextViewerApplet: AppletCommandHandling {
  public var commandSchema: AppletCommandSchema { Self.remoteSchema }

  public func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard !closed else { throw AppletCommandError(.notFound, "the pane is closed") }

    switch command.name {
    case "show-markdown":
      guard case .string(let text)? = command.arguments["text"] else {
        throw AppletCommandError(.badArgument, "the text is missing")
      }

      try requireRoom()
      showInline(text, anchor: nil)

      return try started(.load)

    case "reload":
      guard record.path != nil else {
        throw AppletCommandError(.refused, "the pane shows no file to read again")
      }

      try requireRoom()
      reload()

      return try started(.load)

    case "scroll":
      let anchor = try RemoteAnchor(json: command.arguments["anchor"] ?? .null)

      try requireSettledDocument()
      try requireRoom()

      do {
        return try scroll(to: anchor)
      } catch  where error.code == .badArgument && !shows(command.access) {
        // An anchor past the end of a file the caller may not see would tell it how long the file
        // is. The command answers as it does for a fit, and moves nothing.
        let handle = try begin(.scroll)

        remote.settle(handle, .done(RemoteLanding()))

        return .immediate(handleReply(handle))
      }

    case "find":
      guard case .string(let query)? = command.arguments["query"],
        FindMatching.prepared(query) != nil
      else { throw AppletCommandError(.badArgument, "the query is empty") }

      var backward = false

      if case .bool(let flag)? = command.arguments["backward"] { backward = flag }

      try requireSettledDocument()
      try requireRoom()

      return try find(query, backward: backward)

    case "wait":
      guard case .number(let number)? = command.arguments["handle"] else {
        throw AppletCommandError(.badArgument, "the handle is missing")
      }

      var milliseconds = TextViewerRemote.defaultWait

      if case .number(let given)? = command.arguments["timeout-ms"] { milliseconds = Int(given) }

      let access = command.access

      return try remote.wait(
        for: Int(number), milliseconds: milliseconds,
        mayShow: { [weak self] in self?.shows(access) ?? false })

    default:
      throw AppletCommandError(.unknownCommand, "the viewer has no such command")
    }
  }

  /// True when the caller may be told about the file the pane shows. Content a controller sent
  /// itself and the viewer's own inline text always may be.
  private func shows(_ access: ReadAccess) -> Bool {
    access.mayShow(source: userFileSource)
  }

  // MARK: Handles

  /// A command with an effect refuses before it starts when the pane can keep no more results.
  private func requireRoom() throws(AppletCommandError) {
    guard remote.hasRoom else {
      throw AppletCommandError(
        .busy, "the pane keeps results for too many commands still running. Wait on one first")
    }
  }

  /// The effect has happened, so the reply cannot fail. `requireRoom` checked a moment ago on the
  /// same turn of the main actor, so a handle is always there.
  private func started(_ kind: RemoteHandleTable.Kind) throws(AppletCommandError)
    -> AppletCommandReply
  {
    guard let handle = remote.begin(kind) else {
      throw AppletCommandError(.failed, "the pane could not keep a result for the command")
    }

    return .immediate(handleReply(handle))
  }

  private func handleReply(_ handle: Int) -> JSONValue {
    .object(["handle": .number(Double(handle))])
  }

  /// Scroll and find act on a document that has settled. While a load runs, the answer is busy and
  /// names the load's handle when a command started it. Nothing happens either way.
  private func requireSettledDocument() throws(AppletCommandError) {
    if loadInFlight {
      var message = "a load is running"

      if let handle = remote.activeLoad {
        message += ". Wait on handle \(handle) first"
      } else {
        message += ". Try again once it ends"
      }

      throw AppletCommandError(.busy, message)
    }

    if case .message = content.body {
      throw AppletCommandError(.refused, "the pane shows no document")
    }
  }

  // MARK: Scroll

  private func scroll(to anchor: RemoteAnchor) throws(AppletCommandError) -> AppletCommandReply {
    switch (anchor, content.body) {
    case (.page(let index, let x, let y), .pdf):
      guard let document = content.pdfView.document, index < document.pageCount else {
        throw AppletCommandError(.badArgument, "the page is past the end of the document")
      }

      return place(TextViewerAnchor(page: index, x: x, y: y), handle: try begin(.scroll))

    case (.character(let index), .text):
      guard index < max(1, textLength ?? 0) else {
        throw AppletCommandError(.badArgument, "the character is past the end of the document")
      }

      return place(.text(characterIndex: index), handle: try begin(.scroll))

    case (.line(let line, let fraction), .markdown):
      guard let view = content.markdownView else {
        throw AppletCommandError(.refused, "the pane shows no document")
      }

      let handle = try begin(.scroll)

      landing(handle, view) {
        await view.scroll(to: MarkdownAnchor(line: line, fraction: fraction))
      }

      return .immediate(handleReply(handle))

    case (.heading(let index), _):
      guard contents.entries.indices.contains(index) else {
        throw AppletCommandError(
          .badArgument,
          "the contents list has \(contents.entries.count) entries, and heading \(index) is past its end"
        )
      }

      let entry = contents.entries[index]

      guard case .markdown(let heading) = entry.target else {
        let handle = try begin(.scroll)

        remote.settle(handle, .done(RemoteLanding(anchor: scroll(toEntry: entry))))

        return .immediate(handleReply(handle))
      }

      guard let view = content.markdownView else {
        throw AppletCommandError(.refused, "the pane shows no document")
      }

      let handle = try begin(.scroll)

      landing(handle, view) {
        guard await view.scrollToHeading(heading) else { return nil }

        return await view.landedAnchor()
      }

      return .immediate(handleReply(handle))

    default:
      throw AppletCommandError(
        .badArgument, "the anchor does not fit the kind of document the pane shows")
    }
  }

  private func begin(_ kind: RemoteHandleTable.Kind) throws(AppletCommandError) -> Int {
    guard let handle = remote.begin(kind) else {
      throw AppletCommandError(.busy, "the pane keeps results for too many commands still running")
    }

    return handle
  }

  private func place(_ target: TextViewerAnchor, handle: Int) -> AppletCommandReply {
    remote.settle(handle, .done(RemoteLanding(anchor: place(target))))

    return .immediate(handleReply(handle))
  }

  /// Ends a Markdown scroll when the page reports where it landed. A page that was replaced, or
  /// that stopped, leaves the scroll superseded.
  private func landing(
    _ handle: Int, _ view: MarkdownView, _ scroll: @escaping @MainActor () async -> MarkdownAnchor?
  ) {
    Task { @MainActor [weak self] in
      let landed = await scroll()

      guard let self else { return }

      guard let landed else {
        remote.settle(handle, .superseded)
        return
      }

      remote.settle(
        handle,
        .done(RemoteLanding(anchor: .markdown(line: landed.line, fraction: landed.fraction))))
    }
  }

  // MARK: Find

  private func find(_ query: String, backward: Bool) throws(AppletCommandError)
    -> AppletCommandReply
  {
    let handle = try begin(.find)

    finder.search(query: query, backward: backward) { [weak self] end in
      guard let self else { return }

      switch end {
      case .superseded:
        remote.settle(handle, .superseded)

      case .finished(let landing):
        remote.settle(
          handle,
          .done(
            RemoteLanding(
              count: landing.count, capped: landing.capped, current: landing.current,
              anchor: landing.anchor)))
      }
    }

    return .immediate(handleReply(handle))
  }
}

extension TextViewerApplet: UserFileSourcing {
  public var userFileSource: String? { record.path }
}
