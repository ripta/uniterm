import Foundation

/// `uniterm lint file.janet`.
///
/// It reads the file, parses it, and compares its literal `uniterm` calls with its declaration. It
/// opens no socket, never contacts the app, and runs none of the file's code.
enum ScriptLintCommand {
  /// The lint found something to report.
  static let findings: Int32 = 1

  static let usageText = """
    usage: uniterm lint file.janet

    Compares the calls a script file makes into the uniterm module with the powers its
    (declare-permissions ...) form lists. The lint reads the file and runs none of it. It does not
    contact uniterm.

    It reports a call whose power the file does not declare, a declared power the file never uses,
    and any way the file could make a call the lint cannot see, such as eval or a name built with
    symbol. A declared capability is never reported as unused. A file with no declaration is
    checked as well, and the lint suggests the form to add.

    Each finding is one line, file:line:column: text. The exit status is 0 when the file is clean,
    1 when it has findings, 65 when the file or its declaration does not read, and 66 when the file
    cannot be opened. The lint is best effort. A file it calls clean can still be refused at run
    time, and the run enforces the declaration whatever the lint said.
    """

  static func run(arguments: [String]) -> Int32 {
    var path: String?
    var options = true

    for argument in arguments {
      if options, argument == "--" {
        options = false
      } else if options, argument == "-h" || argument == "--help" {
        print(usageText)

        return ScriptHelperMain.Exit.ok
      } else if options, argument.hasPrefix("-"), argument != "-" {
        return ScriptHelperMain.fail(
          "unknown option \(argument)\n\(usageText)", status: ScriptHelperMain.Exit.usage)
      } else if path == nil {
        path = argument
      } else {
        return ScriptHelperMain.fail(
          "uniterm lint takes one file\n\(usageText)", status: ScriptHelperMain.Exit.usage)
      }
    }

    guard let path else {
      return ScriptHelperMain.fail(usageText, status: ScriptHelperMain.Exit.usage)
    }

    if ControllerCommands.isPackage(path) {
      return ScriptHelperMain.fail(
        "\(path) is a folder. uniterm lint reads a script file, not a package.",
        status: ScriptHelperMain.Exit.usage)
    }

    let source: Data

    do {
      source = try ScriptHelperMain.readScript(at: path)
    } catch {
      return ScriptHelperMain.fail(
        "cannot read \(path): \(error.localizedDescription)",
        status: ScriptHelperMain.Exit.noInput)
    }

    switch ScriptLint.lint(source) {
    case .unreadable(let text):
      return ScriptHelperMain.fail("\(path): \(text)", status: ScriptHelperMain.Exit.dataError)

    case .report(let found, let suggestion):
      for finding in found {
        print("\(path):\(finding.line):\(finding.column): \(finding.message)")
      }

      if let suggestion { print("\(path): \(suggestion)") }

      return found.isEmpty ? ScriptHelperMain.Exit.ok : findings
    }
  }
}
