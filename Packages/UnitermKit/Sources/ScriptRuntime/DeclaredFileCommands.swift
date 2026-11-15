import CJanet
import ControllerPackage
import Darwin
import Foundation
import ScriptWire

/// `uniterm run` with a script file whose first form declares its powers.
///
/// The command resolves the file's path and asks the app to admit it. The app reads the file
/// itself, copies it, and answers with the copy and the SHA-256 of the whole file. The command
/// reads the copy once, checks its hash before it parses anything, reads the declaration from
/// those bytes, and reports it to the app. Only when the app admits the run does the command run
/// the bytes it hashed. It never reads the copy again, and never runs what it read from the path.
enum DeclaredFileCommands {
  static func run(
    script: String, allowed: [String], denied: UInt32, arguments: [String],
    address: ScriptHelperMain.Address
  ) -> Int32 {
    guard let resolved = realpath(script) else {
      return ScriptHelperMain.fail(
        "cannot find the file \(script)", status: ScriptHelperMain.Exit.noInput)
    }

    let opened: (session: ScriptSession, snapshot: String, version: Data)

    do {
      opened = try ScriptSession.openFile(
        path: address.path, begin: FileBegin(path: resolved, capabilities: allowed))
    } catch {
      return ScriptHelperMain.connectionFailure(error, address: address)
    }

    let session = opened.session
    let bytes: Data

    do {
      bytes = try DeclaredFileSnapshot.read(at: opened.snapshot, version: opened.version)
    } catch {
      session.close()

      return ScriptHelperMain.fail(
        "uniterm's copy of the script did not verify: \(error)",
        status: ScriptHelperMain.Exit.unavailable)
    }

    let declaration: String

    switch DeclaredScript.read(bytes) {
    case .declared(let json):
      declaration = json

    case .undeclared:
      session.close()

      return ScriptHelperMain.fail(
        "\(script): the file's first form is not (declare-permissions ...), so uniterm will not "
          + "run it as a declared file. It may have changed after uniterm began to read it.",
        status: ScriptHelperMain.Exit.dataError)

    case .invalid(let text):
      session.close()

      return ScriptHelperMain.fail("\(script): \(text)", status: ScriptHelperMain.Exit.dataError)
    }

    do {
      _ = try FileDeclaration.parse(declaration)
      try session.declare(declaration)
    } catch ControllerPackageError.declaration(let text) {
      session.close()

      return ScriptHelperMain.fail(
        "\(script): the declaration is not one uniterm reads: \(text)",
        status: ScriptHelperMain.Exit.dataError)
    } catch {
      session.close()

      return ScriptHelperMain.connectionFailure(error, address: address)
    }

    uniterm_janet_block_sigint()

    let watchdog = ScriptWatchdog.start(
      reading: session, onStop: { uniterm_janet_request_interrupt() },
      onHangup: { ScriptSession.endHelper(ScriptSession.appQuitText, flushingOutput: false) })

    defer {
      watchdog.finish()
      session.close()
    }

    uniterm_janet_enable_run_sigint()

    let name = URL(fileURLWithPath: script).lastPathComponent

    guard
      let failure = ScriptVM.runDeclared(
        name: name, source: bytes, session: session, sandbox: denied,
        arguments: [script] + arguments)
    else { return ScriptHelperMain.Exit.ok }

    return ScriptHelperMain.fail(
      failure.description,
      status: failure.kind == .interrupted
        ? ScriptHelperMain.Exit.interrupted : ScriptHelperMain.Exit.scriptFailed)
  }

  private static func realpath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }

    defer { free(resolved) }

    return String(cString: resolved)
  }
}
