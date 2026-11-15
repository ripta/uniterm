import CJanet
import ControllerPackage
import Darwin
import Foundation
import ScriptWire

/// The command's controller modes: running a Janet or a native controller package, and signing
/// one.
///
/// A run asks the app first. The app authenticates this command, verifies the package itself, and
/// answers with a private snapshot of it. Only the snapshot is loaded, and only once its descriptor
/// has the digest the app verified, so nothing of the package runs before the app admits it. The
/// command keeps its own standard streams, signals, working directory, and exit status throughout.
enum ControllerCommands {
  static var usageText: String {
    """
    usage: uniterm controller run [--socket PATH] package [argument...]
           uniterm controller sign --key NAME package
           uniterm controller keygen NAME

    run      runs a package's native entry, from uniterm's verified copy of the package.
    sign     signs a package's controller.json with the key NAME in your login Keychain, and
             writes controller.sig. A missing key is an error. No other key signs in its place.
    keygen   makes a new signing key NAME in your login Keychain. It never replaces a key.

    A package with a Janet entry runs with uniterm run instead: uniterm run [--allow CAPABILITY]...
    package [argument...].
    """
  }

  /// Variables that make dyld load code the package does not hold.
  ///
  /// The bundle's command has the hardened runtime, so dyld drops them before the command runs
  /// and the entry it execs never sees them. A command built without it, such as the package
  /// tests' helper, still has them, and a run then refuses to start: the command cannot tell a
  /// variable the user meant for this run from one the shell carried along.
  ///
  /// `__XPC_DYLD_` variables are not among them. dyld never reads them. launchd turns them into
  /// dyld variables only for an XPC service it starts, and Xcode sets them for an app under test,
  /// whose terminals pass them on.
  static func loaderVariables(in environment: [String: String]) -> [String] {
    environment.keys.filter { $0.hasPrefix("DYLD_") }.sorted()
  }

  static func loaderRefusal(_ environment: [String: String]) -> String? {
    let found = loaderVariables(in: environment)

    guard !found.isEmpty else { return nil }

    return
      "uniterm will not run a controller while \(found.joined(separator: ", ")) is set. A "
      + "controller loads code only from its package and the system. Unset it and run again."
  }

  /// True when `path` is a folder, which `uniterm run` takes as a package.
  static func isPackage(_ path: String) -> Bool {
    var isFolder: ObjCBool = false

    return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
      && isFolder.boolValue
  }

  /// `uniterm run` with a package: the Janet entry runs in this process's VM, once admitted.
  static func runJanet(
    package: String, allowed: [String], denied: UInt32, arguments: [String],
    address: ScriptHelperMain.Address, environment: [String: String]
  ) -> Int32 {
    if let refusal = loaderRefusal(environment) {
      return ScriptHelperMain.fail(refusal, status: ScriptHelperMain.Exit.usage)
    }

    guard let resolved = realpath(package) else {
      return ScriptHelperMain.fail(
        "cannot find the package \(package)", status: ScriptHelperMain.Exit.noInput)
    }

    let opened: (session: ScriptSession, snapshot: String, version: Data)

    do {
      opened = try ScriptSession.openController(
        path: address.path,
        begin: ControllerBegin(entry: .janet, package: resolved, capabilities: allowed))
    } catch {
      return ScriptHelperMain.connectionFailure(error, address: address)
    }

    let session = opened.session
    let loaded: (descriptor: ControllerDescriptor, files: [String: Data])

    do {
      loaded = try ControllerSnapshot.load(at: opened.snapshot, version: opened.version)
    } catch {
      session.close()

      return ScriptHelperMain.fail(
        "uniterm's copy of the controller did not verify: \(error)",
        status: ScriptHelperMain.Exit.unavailable)
    }

    guard loaded.descriptor.entryKind == .janet else {
      session.close()

      return ScriptHelperMain.fail(
        "the package's entry is not Janet", status: ScriptHelperMain.Exit.unavailable)
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

    let entry = loaded.descriptor.entryPath

    guard
      let failure = ScriptVM.runPackage(
        name: entry, entry: entry, files: loaded.files, session: session, sandbox: denied,
        arguments: [package] + arguments)
    else { return ScriptHelperMain.Exit.ok }

    return ScriptHelperMain.fail(
      failure.description,
      status: failure.kind == .interrupted
        ? ScriptHelperMain.Exit.interrupted : ScriptHelperMain.Exit.scriptFailed)
  }

  /// `uniterm controller ...`.
  static func run(
    arguments: [String], environment: [String: String],
    keys: any ControllerKeyStore = KeychainKeyStore()
  ) -> Int32 {
    switch arguments.first {
    case "run": return runNative(Array(arguments.dropFirst()), environment: environment)
    case "sign": return sign(Array(arguments.dropFirst()), keys: keys)
    case "keygen": return keygen(Array(arguments.dropFirst()), keys: keys)
    case "-h", "--help", nil:
      print(usageText)

      return arguments.isEmpty ? ScriptHelperMain.Exit.usage : ScriptHelperMain.Exit.ok
    default:
      return ScriptHelperMain.fail(
        "unknown controller command \"\(arguments[0])\"\n\(usageText)",
        status: ScriptHelperMain.Exit.usage)
    }
  }

  /// Asks the app to admit the native run, then execs the snapshot's entry in this process. The
  /// entry inherits this process's terminal, so the pane it runs in is the one the command ran in.
  private static func runNative(_ arguments: [String], environment: [String: String]) -> Int32 {
    var socket: String?
    var rest = arguments

    while let first = rest.first, first.hasPrefix("-") {
      guard first == "--socket", rest.count > 1 else {
        return ScriptHelperMain.fail(
          "unknown option \(first)\n\(usageText)", status: ScriptHelperMain.Exit.usage)
      }

      socket = rest[1]
      rest.removeFirst(2)
    }

    guard let package = rest.first else {
      return ScriptHelperMain.fail(
        "a package is needed\n\(usageText)", status: ScriptHelperMain.Exit.usage)
    }

    if let refusal = loaderRefusal(environment) {
      return ScriptHelperMain.fail(refusal, status: ScriptHelperMain.Exit.usage)
    }

    let address: ScriptHelperMain.Address

    do {
      address = try ScriptHelperMain.Address.resolve(socket: socket, environment: environment)
    } catch {
      return ScriptHelperMain.fail("\(error)", status: ScriptHelperMain.Exit.unavailable)
    }

    guard let resolved = realpath(package) else {
      return ScriptHelperMain.fail(
        "cannot find the package \(package)", status: ScriptHelperMain.Exit.noInput)
    }

    let opened: (session: ScriptSession, snapshot: String, version: Data)

    do {
      opened = try ScriptSession.openController(
        path: address.path, begin: ControllerBegin(entry: .native, package: resolved))
    } catch {
      return ScriptHelperMain.connectionFailure(error, address: address)
    }

    defer { opened.session.close() }

    let descriptor: ControllerDescriptor

    do {
      descriptor = try ControllerSnapshot.load(at: opened.snapshot, version: opened.version)
        .descriptor
    } catch {
      return ScriptHelperMain.fail(
        "uniterm's copy of the controller did not verify: \(error)",
        status: ScriptHelperMain.Exit.unavailable)
    }

    guard descriptor.entryKind == .native else {
      return ScriptHelperMain.fail(
        "the package's entry is not native", status: ScriptHelperMain.Exit.unavailable)
    }

    opened.session.close()

    let entry = (opened.snapshot as NSString).appendingPathComponent(descriptor.entryPath)
    var child = environment.filter { loaderVariables(in: [$0.key: $0.value]).isEmpty }

    child[ScriptHelperMain.addressVariable] = address.path

    let argv = [entry] + Array(rest.dropFirst())
    let envp = child.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }

    withCStringArray(argv) { argvPointers in
      withCStringArray(envp) { envpPointers in
        _ = execve(entry, argvPointers, envpPointers)
      }
    }

    return ScriptHelperMain.fail(
      "cannot start the controller's entry: \(String(cString: strerror(errno)))",
      status: ScriptHelperMain.Exit.unavailable)
  }

  static func sign(_ arguments: [String], keys: any ControllerKeyStore) -> Int32 {
    guard arguments.count == 3, arguments[0] == "--key" else {
      return ScriptHelperMain.fail(
        "sign needs --key NAME and a package\n\(usageText)", status: ScriptHelperMain.Exit.usage)
    }

    let package = arguments[2]

    do {
      let key = try keys.key(named: arguments[1])
      let descriptor = try ControllerSnapshot.descriptorForSigning(at: package)
      let identity = try ControllerDescriptor.parse(descriptor)
      let signature = try ControllerSignature.sign(descriptor: descriptor, with: key)
      let target = URL(fileURLWithPath: package).appendingPathComponent(
        ControllerSignature.fileName)

      try signature.encoded().write(to: target, options: .atomic)
      print("signed \(identity.id), version \(identity.versionHex)")
      print("key \(signature.keyFingerprint)")

      return ScriptHelperMain.Exit.ok
    } catch {
      return ScriptHelperMain.fail(
        "cannot sign \(package): \(error)", status: ScriptHelperMain.Exit.noInput)
    }
  }

  static func keygen(_ arguments: [String], keys: any ControllerKeyStore) -> Int32 {
    guard arguments.count == 1 else {
      return ScriptHelperMain.fail(
        "keygen needs one NAME\n\(usageText)", status: ScriptHelperMain.Exit.usage)
    }

    do {
      let key = try keys.create(named: arguments[0])

      print(
        "key \(ControllerSignature(publicKey: key.publicKey, signature: Data()).keyFingerprint)")

      return ScriptHelperMain.Exit.ok
    } catch {
      return ScriptHelperMain.fail("\(error)", status: ScriptHelperMain.Exit.noInput)
    }
  }

  private static func realpath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }

    defer { free(resolved) }

    return String(cString: resolved)
  }

  private static func withCStringArray(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Void
  ) {
    let copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]

    defer { for copy in copies { free(copy) } }

    copies.withUnsafeBufferPointer { body($0.baseAddress!) }
  }
}
