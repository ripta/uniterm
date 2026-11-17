import Darwin
import Foundation
import ScriptWire

/// `uniterm open [--socket PATH] [--] path...`.
///
/// The command resolves each relative path against its own physical working directory and sends
/// absolute paths. It never calls `realpath`, `stat`, or `open` on a target, so a path it names is
/// touched only by the app, after the user allowed the request. Nothing about the working directory
/// itself crosses the socket.
///
/// The app answers the same way whether a file opened, was missing, or no applet opens it, and the
/// answer carries no content. Exit status 0 therefore says only that the app took the request.
enum ScriptOpenCommand {
  static let usageText = """
    usage: uniterm open [--socket PATH] [--] path...

    Asks the running uniterm to open each path in a new pane beside the one this command runs in.
    A folder opens a terminal there. A relative path means what your shell means by it. uniterm
    shows you the paths and asks before it opens anything, unless you allowed this terminal
    session earlier.

    The command exits 0 once uniterm took the request. That says nothing about any file, since a
    missing file, a type no applet opens, and a file that opened all look the same here. uniterm
    reports what it could not open in its own status bar.

      --socket PATH  connect to the uniterm at PATH, which wins over UNITERM_SOCKET.
      -h, --help     show this text.
    """

  /// What the command was asked to do.
  struct Invocation: Equatable {
    var socket: String?
    var paths: [String] = []
  }

  enum Parsed: Equatable {
    case open(Invocation)
    case help
    case usage(String)
  }

  static func parse(_ arguments: [String]) -> Parsed {
    var invocation = Invocation()
    var index = 0
    var options = true

    while index < arguments.count {
      let argument = arguments[index]

      if options, argument == "--" {
        options = false
        index += 1
      } else if options, argument == "-h" || argument == "--help" {
        return .help
      } else if options, argument == "--socket" {
        guard index + 1 < arguments.count else { return .usage("--socket needs a value") }

        invocation.socket = arguments[index + 1]
        index += 2
      } else if options, argument.hasPrefix("-"), argument != "-" {
        return .usage("unknown option \(argument)")
      } else {
        invocation.paths.append(argument)
        index += 1
      }
    }

    guard !invocation.paths.isEmpty else { return .usage("a path is needed") }

    return .open(invocation)
  }

  /// Why the paths cannot be resolved: an argument that is not text, or a working directory that
  /// is gone.
  struct Problem: Error, Equatable {
    let text: String
    let status: Int32
  }

  /// Makes each path absolute by joining it to `directory`, as a string. It never looks at the
  /// target and does no cleanup of `.` or `..`, since only the kernel knows what a link on the way
  /// makes of them. An absolute path is sent as written. `directory` is read only when a relative
  /// path needs it.
  static func resolve(
    _ arguments: [String], directory: () throws -> String
  ) throws -> [String] {
    var base: String?
    var resolved: [String] = []

    for argument in arguments {
      guard !argument.isEmpty else {
        throw Problem(text: "a path is empty", status: ScriptHelperMain.Exit.usage)
      }

      guard !argument.unicodeScalars.contains("\u{FFFD}") else {
        throw Problem(
          text: "a path is not valid UTF-8, so uniterm cannot name the file",
          status: ScriptHelperMain.Exit.usage)
      }

      if argument.hasPrefix("/") {
        resolved.append(argument)

        continue
      }

      if base == nil { base = try directory() }

      let root = base ?? "/"

      resolved.append(root == "/" ? "/" + argument : root + "/" + argument)
    }

    return resolved
  }

  /// The command's physical working directory. `getcwd` names it, and `realpath` of that one
  /// directory removes any link or firmlink the name still holds. A deleted directory has no name,
  /// so it fails here, with a message, before anything is sent.
  static func physicalWorkingDirectory() throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)

    guard getcwd(&buffer, buffer.count) != nil else {
      throw Problem(
        text: "the working directory no longer exists, so a relative path has nothing to resolve "
          + "against: \(String(cString: strerror(errno)))",
        status: ScriptHelperMain.Exit.noInput)
    }

    var real = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)

    guard realpath(buffer, &real) != nil else {
      throw Problem(
        text: "the working directory cannot be resolved: \(String(cString: strerror(errno)))",
        status: ScriptHelperMain.Exit.noInput)
    }

    let bytes = real.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

    guard let name = String(validating: bytes, as: UTF8.self) else {
      throw Problem(
        text: "the working directory's name is not valid UTF-8, so uniterm cannot name it",
        status: ScriptHelperMain.Exit.noInput)
    }

    return name
  }

  static func run(
    arguments: [String], environment: [String: String],
    directory: () throws -> String = physicalWorkingDirectory
  ) -> Int32 {
    let invocation: Invocation

    switch parse(arguments) {
    case .help:
      print(usageText)

      return ScriptHelperMain.Exit.ok

    case .usage(let problem):
      return ScriptHelperMain.fail(
        "\(problem)\n\(usageText)", status: ScriptHelperMain.Exit.usage)

    case .open(let parsed):
      invocation = parsed
    }

    let paths: [String]

    do {
      paths = try resolve(invocation.paths, directory: directory)
    } catch let problem as Problem {
      return ScriptHelperMain.fail(problem.text, status: problem.status)
    } catch {
      return ScriptHelperMain.fail("\(error)", status: ScriptHelperMain.Exit.usage)
    }

    if let problem = OpenBegin.problem(with: paths) {
      return ScriptHelperMain.fail(
        "uniterm cannot open that: \(problem)", status: ScriptHelperMain.Exit.usage)
    }

    let address: ScriptHelperMain.Address

    do {
      address = try ScriptHelperMain.Address.resolve(
        socket: invocation.socket, environment: environment)
    } catch {
      return ScriptHelperMain.fail("\(error)", status: ScriptHelperMain.Exit.unavailable)
    }

    do {
      try ScriptSession.open(path: address.path, begin: OpenBegin(paths: paths))

      return ScriptHelperMain.Exit.ok
    } catch WireError.closed {
      return ScriptHelperMain.fail(
        "uniterm closed the connection before it answered",
        status: ScriptHelperMain.Exit.connectionLost)
    } catch {
      return ScriptHelperMain.connectionFailure(error, address: address)
    }
  }
}
