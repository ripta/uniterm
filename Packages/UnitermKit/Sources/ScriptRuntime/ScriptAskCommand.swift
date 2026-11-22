import Darwin
import Foundation
import ScriptWire

/// `uniterm ask`, which shows the user a form and prints the answer.
///
/// The command opens a question-only session, which runs no script code and may make only the three
/// form calls. It opens the form, waits for the user, and discards the form's handle on every way
/// out. Ctrl-C keeps its default action, so the shell reports 130, and the connection closing is
/// what ends the form in the app.
///
/// The command checks the shape of its own flags and sends the app a form. The app reads the form
/// strictly and checks its meaning, so a form the app refuses exits with the spec error status.
enum ScriptAskCommand {
  static let usageText = """
    usage: uniterm ask form [--socket PATH] < form.json
           uniterm ask confirm [--json] [--socket PATH] [--] prompt
           uniterm ask text [--default TEXT] [--pattern REGEX] [--json] [--socket PATH] [--] prompt
           uniterm ask choose [--multiple | --other] [--json] [--socket PATH] [--] prompt choice...
           uniterm ask number [--integer] [--min N] [--max N] [--json] [--socket PATH] [--] prompt
           uniterm ask color [--json] [--socket PATH] [--] prompt
           uniterm ask file [--directory | --save] [--type UTI]... [--json] [--socket PATH] [--]
                            prompt

    Shows the user a form in uniterm's Questions pane and waits for the answer. uniterm names the
    program that asks, and the form cannot change that.

    form reads a full form as JSON on standard input and prints the result as JSON. Each other
    command asks one question and prints only its answer. A list of answers is one to a line, and
    --json prints the answer as JSON instead.

    Exit status:
       0  the user answered. For confirm, the answer is Yes.
       1  confirm only: the answer is No.
       3  the user cancelled the form or closed it.
       4  the form ended before it was answered, such as when uniterm revoked this program.
      64  usage error.
      65  the form is not valid. The message names the field.
      69  uniterm is not reachable, or it failed to ask.
      70  this command and uniterm are different versions.
      74  the connection to uniterm was lost.
      75  uniterm holds as many forms as it may from this program. Try again.
      77  uniterm refused to ask, such as when this program was denied a pane.
      78  this is not the command inside the uniterm app.
     130  Ctrl-C.

    Nothing is printed on standard output unless the exit status is 0. Every status but 0 and 1
    prints one line on standard error that says why.

      --socket PATH  connect to the uniterm at PATH, which wins over UNITERM_SOCKET.
      -h, --help     show this text.
    """

  enum Kind: String, CaseIterable {
    case form, confirm, text, choose, number, color, file
  }

  struct Invocation: Equatable {
    var kind: Kind
    var socket: String?
    var json = false
    var prompt = ""
    var choices: [String] = []
    var defaultText: String?
    var pattern: String?
    var multiple = false
    var other = false
    var integer = false
    var minimum: String?
    var maximum: String?
    var mode = "open"
    var types: [String] = []
  }

  enum Parsed: Equatable {
    case ask(Invocation)
    case help
    case usage(String)
  }

  /// Reads the words after `uniterm ask`.
  static func parse(_ arguments: [String]) -> Parsed {
    guard let first = arguments.first else { return .usage("a kind of question is needed") }

    if first == "-h" || first == "--help" { return .help }

    guard let kind = Kind(rawValue: first) else {
      return .usage("unknown kind of question \"\(first)\"")
    }

    var invocation = Invocation(kind: kind)
    var positional: [String] = []
    var index = 1
    var options = true

    func value(of flag: String) -> String? {
      guard index + 1 < arguments.count else { return nil }

      defer { index += 2 }

      return arguments[index + 1]
    }

    while index < arguments.count {
      let argument = arguments[index]

      guard options, argument.hasPrefix("-"), argument != "-" else {
        positional.append(argument)
        index += 1

        continue
      }

      switch (argument, kind) {
      case ("--", _):
        options = false
        index += 1

      case ("-h", _), ("--help", _):
        return .help

      case ("--json", _) where kind != .form:
        invocation.json = true
        index += 1

      case ("--socket", _):
        guard let path = value(of: argument) else { return .usage("--socket needs a value") }

        invocation.socket = path

      case ("--default", .text):
        guard let text = value(of: argument) else { return .usage("--default needs a value") }

        invocation.defaultText = text

      case ("--pattern", .text):
        guard let text = value(of: argument) else { return .usage("--pattern needs a value") }

        invocation.pattern = text

      case ("--multiple", .choose):
        invocation.multiple = true
        index += 1

      case ("--other", .choose):
        invocation.other = true
        index += 1

      case ("--integer", .number):
        invocation.integer = true
        index += 1

      case ("--min", .number), ("--max", .number):
        guard let literal = value(of: argument) else { return .usage("\(argument) needs a value") }

        guard ScriptAskSpec.isJSONNumber(literal) else {
          return .usage("\(argument) needs a number, not \"\(literal)\"")
        }

        if argument == "--min" {
          invocation.minimum = literal
        } else {
          invocation.maximum = literal
        }

      case ("--directory", .file), ("--save", .file):
        let mode = argument == "--directory" ? "directory" : "save"

        guard invocation.mode == "open" || invocation.mode == mode else {
          return .usage("--directory and --save cannot go together")
        }

        invocation.mode = mode
        index += 1

      case ("--type", .file):
        guard let uti = value(of: argument) else { return .usage("--type needs a value") }

        invocation.types.append(uti)

      default:
        return .usage("unknown option \(argument)")
      }
    }

    switch kind {
    case .form:
      guard positional.isEmpty else {
        return .usage("ask form takes its form on standard input, not as an argument")
      }

    case .choose:
      guard let prompt = positional.first else { return .usage("a prompt is needed") }

      guard positional.count > 1 else { return .usage("at least one choice is needed") }

      guard !(invocation.multiple && invocation.other) else {
        return .usage(
          "--multiple and --other cannot go together, since only one choice takes an "
            + "answer of the user's own")
      }

      invocation.prompt = prompt
      invocation.choices = Array(positional.dropFirst())

    default:
      guard let prompt = positional.first else { return .usage("a prompt is needed") }

      guard positional.count == 1 else {
        return .usage("ask \(kind.rawValue) takes one prompt, and got \(positional.count) words")
      }

      invocation.prompt = prompt
    }

    return .ask(invocation)
  }

  /// The form to send for a shorthand.
  static func spec(for invocation: Invocation) -> ScriptAskSpec? {
    let prompt = invocation.prompt

    switch invocation.kind {
    case .form: return nil
    case .confirm: return .confirm(prompt)

    case .text:
      return .text(prompt, default: invocation.defaultText, pattern: invocation.pattern)

    case .choose:
      return .choose(
        prompt, choices: invocation.choices, multiple: invocation.multiple,
        other: invocation.other)

    case .number:
      return .number(
        prompt, integer: invocation.integer, minimum: invocation.minimum,
        maximum: invocation.maximum)

    case .color: return .color(prompt)

    case .file: return .file(prompt, mode: invocation.mode, types: invocation.types)
    }
  }

  // MARK: Running

  /// What the command says when uniterm's end of the connection closes.
  static let quitText = "uniterm quit, or closed the connection, before the form was answered"

  static func run(
    arguments: [String], environment: [String: String],
    standardInput: () throws -> Data = readStandardInput
  ) -> Int32 {
    let invocation: Invocation

    switch parse(arguments) {
    case .help:
      print(usageText)

      return ScriptHelperMain.Exit.ok

    case .usage(let problem):
      return ScriptHelperMain.fail("\(problem)\n\(usageText)", status: ScriptHelperMain.Exit.usage)

    case .ask(let parsed):
      invocation = parsed
    }

    let spec: String

    if let built = Self.spec(for: invocation) {
      spec = built.text
    } else {
      do {
        let data = try standardInput()

        guard let text = String(validating: data, as: UTF8.self) else {
          return ScriptHelperMain.fail(
            "the form on standard input is not UTF-8", status: ScriptHelperMain.Exit.dataError)
        }

        spec = text
      } catch {
        return ScriptHelperMain.fail(
          "cannot read the form on standard input: \(error)",
          status: ScriptHelperMain.Exit.dataError)
      }
    }

    guard spec.utf8.count <= ScriptProtocol.maxFormBytes else {
      return ScriptHelperMain.fail(
        "the form is larger than \(ScriptProtocol.maxFormBytes) bytes",
        status: ScriptHelperMain.Exit.dataError)
    }

    let address: ScriptHelperMain.Address

    do {
      address = try ScriptHelperMain.Address.resolve(
        socket: invocation.socket, environment: environment)
    } catch {
      return ScriptHelperMain.fail("\(error)", status: ScriptHelperMain.Exit.unavailable)
    }

    let session: ScriptSession

    do {
      session = try ScriptSession.openQuestionOnly(path: address.path, quitText: quitText)
    } catch {
      return ScriptHelperMain.connectionFailure(error, address: address)
    }

    defer { session.close() }

    return ask(invocation, spec: spec, on: session)
  }

  private static func ask(_ invocation: Invocation, spec: String, on session: ScriptSession)
    -> Int32
  {
    let form: UInt64

    do {
      form = try ScriptAskOutput.handle(of: try session.call(.openForm(spec: spec)))
    } catch {
      return failure(error)
    }

    let status: Int32

    do {
      let payload = try session.call(.waitForm(form: form))

      let value = try ScriptValue.decode(payload)

      status = report(try ScriptAskOutput.result(of: value), value, invocation)
    } catch {
      status = failure(error)
    }

    session.discardQuietly(form)

    return status
  }

  /// Writes the answer, or the reason there is none, and returns the exit status.
  private static func report(
    _ result: ScriptAskOutput.Result, _ value: ScriptValue, _ invocation: Invocation
  ) -> Int32 {
    switch result {
    case .dismissed:
      return ScriptHelperMain.fail(
        "the form was closed without an answer", status: ScriptHelperMain.Exit.cancelled)

    case .cancelled:
      if invocation.kind == .confirm { return ScriptHelperMain.Exit.scriptFailed }

      return ScriptHelperMain.fail(
        "the form was cancelled", status: ScriptHelperMain.Exit.cancelled)

    case .answered(_, let answers):
      var lines: [String] = []

      switch invocation.kind {
      case .form:
        lines = [ScriptAskOutput.json(value)]

      case .confirm:
        if invocation.json { lines = ["true"] }

      default:
        let answer = answers[ScriptAskSpec.answerID] ?? .null

        lines = invocation.json ? [ScriptAskOutput.json(answer)] : ScriptAskOutput.lines(of: answer)
      }

      let output = Data(lines.map { $0 + "\n" }.joined().utf8)

      if let code = ScriptHelperMain.writeAll(output, to: STDOUT_FILENO) {
        return ScriptHelperMain.fail(
          "cannot write the answer: \(String(cString: strerror(code)))",
          status: ScriptHelperMain.Exit.connectionLost)
      }

      return ScriptHelperMain.Exit.ok
    }
  }

  /// The exit status for a call that did not complete, with the reason on standard error.
  private static func failure(_ error: any Error) -> Int32 {
    switch error {
    case ScriptSessionError.failed(let kind, let text):
      return ScriptHelperMain.fail(text, status: ScriptAskOutput.status(for: kind))

    case let unreadable as ScriptAskOutput.Unreadable:
      return ScriptHelperMain.fail(unreadable.text, status: ScriptHelperMain.Exit.unavailable)

    default:
      return ScriptHelperMain.fail(
        "uniterm sent an answer this command cannot read: \(error)",
        status: ScriptHelperMain.Exit.unavailable)
    }
  }

  /// All of standard input, up to one byte past the form's limit, so a form that is too large is
  /// seen as too large and never cut.
  static func readStandardInput() throws -> Data {
    var data = Data()

    while let chunk = try FileHandle.standardInput.read(upToCount: 1 << 14), !chunk.isEmpty {
      data.append(chunk)

      if data.count > ScriptProtocol.maxFormBytes { break }
    }

    return data
  }
}
