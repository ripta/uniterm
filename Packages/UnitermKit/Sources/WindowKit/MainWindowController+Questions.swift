import AppKit
import PaneModel
import QuestionForm
import QuestionsApplet
import ScriptHost
import ScriptWire

/// What a pane's asking badge shows: that a form that this pane asked waits for the user, and
/// where.
struct PaneAskingMark: Equatable {
  /// The Questions pane that holds the form, as the pane's stable ID names it.
  var questionsPane: String

  var summary: String { "Waiting for your answer in \(questionsPane)" }
}

extension MainWindowController {
  /// The window's Questions pane, if one is open. The first in reading order when there are more.
  func questionsPane() -> (pane: NodeID, applet: QuestionsApplet)? {
    for pane in paneArea.tree.paneIDs {
      if let applet = paneArea.applet(for: pane) as? QuestionsApplet, !applet.isClosed {
        return (pane, applet)
      }
    }

    return nil
  }

  /// The applet of the window's Questions pane, if one is open.
  public var questionsApplet: QuestionsApplet? { questionsPane()?.applet }

  /// Shows a form for a program that acts from `asker`. The window's Questions pane takes it. When
  /// the window has none, a new one opens beside the asker and takes focus as a split the user
  /// makes does. The form's tab takes focus as a tab the user opens does.
  ///
  /// Nothing changes when the form is refused. The new pane is placed only when no Questions pane
  /// exists, and then the form cannot be refused as busy.
  func openForm(
    _ spec: FormSpec, requester: FormRequester, asker: NodeID,
    resolved: @escaping @MainActor (FormOutcome) -> Void
  ) throws(ScriptCallError) {
    let asking = QuestionsRequester(
      key: requester.key, name: requester.name,
      askingPane: .open(label: Self.paneLabel(asker)))

    let applet: QuestionsApplet
    let hostPane: NodeID

    if let existing = questionsPane() {
      applet = existing.applet
      hostPane = existing.pane
    } else {
      let created = QuestionsApplet()

      guard let placed = placeRouted(created, beside: asker) else {
        created.close()

        throw .refused(
          "there is no room beside the pane to open a Questions pane. Close a pane and try again")
      }

      applet = created
      hostPane = placed
    }

    let result = applet.open(spec, for: asking) { [weak self] outcome in
      self?.askers[requester.key] = nil
      self?.refreshControlMarks()

      resolved(outcome)
    }

    switch result {
    case .busy(.requesterHasOpenForm):
      throw .busy(
        "This program has a form open already. Wait for its answer before asking another.")

    case .busy(.paneFull):
      throw .busy("The Questions pane holds as many open forms as it may. Try again later.")

    case .busy(.unavailable):
      throw .refused("the Questions pane closed")

    case .opened:
      break
    }

    askers[requester.key] = asker

    paneArea.focus(hostPane)

    refreshControlMarks()
  }

  /// The requester let go of its form. An open form ends, and its tab stays.
  func discardForm(requester key: String) {
    guard let applet = questionsPane()?.applet, let tab = applet.tab(forRequester: key) else {
      return
    }

    applet.discard(tab: tab)
  }

  /// The requester ended. Its tab goes, and an open form in it ends.
  func endForm(requester key: String) {
    questionsPane()?.applet.end(requester: key)
  }

  /// A pane closed. The header of each form it asked says the pane is gone, and never points at
  /// another pane.
  func askerPaneClosed(_ pane: NodeID) {
    guard askers.values.contains(pane) else { return }

    questionsPane()?.applet.askingPaneDidClose(label: Self.paneLabel(pane))
  }

  /// The refusal for a layout that the window's Questions pane blocks, or nil when the planner's
  /// error has another cause. A Questions pane that opened beside a pane of the group joins the
  /// group's content and not its members, so the group holds a pane its owner does not own. The
  /// pane stays, resolved tabs included, until the user closes it or its last tab goes.
  ///
  /// The refusal applies only when that pane is the one unowned pane. Another unowned pane makes
  /// the planner's own message the right one, since closing the Questions pane would not help.
  func questionsPaneBlocks(_ error: any Error) -> ScriptCallError? {
    guard case PaneLayoutError.unownedContent(let unowned) = error,
      let questions = questionsPane()?.pane, unowned == [questions]
    else { return nil }

    return .refused(
      "the group holds the Questions pane that a form opened beside one of its panes, which this "
        + "program does not own, so its layout cannot change. Close the Questions pane, or lay "
        + "out again once the form's tab has closed and the pane with it")
  }

  /// The badge's mark for a pane, or nil when no open form was asked from it.
  func askingMark(for pane: NodeID) -> PaneAskingMark? {
    guard askers.values.contains(pane), let questions = questionsPane() else { return nil }

    return PaneAskingMark(questionsPane: Self.paneLabel(questions.pane))
  }

  static func paneLabel(_ pane: NodeID) -> String { "Pane \(pane.rawValue)" }
}
