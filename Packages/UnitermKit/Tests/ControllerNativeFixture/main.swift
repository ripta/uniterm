import Darwin
import Foundation
import ScriptWire

// A native controller for the tests. It reports what it was started with, connects to the app at
// UNITERM_SOCKET, makes one call, reports the answer, and exits with the status its last argument
// names, or 0. With "wait" among its arguments, it waits for a signal instead of exiting. With
// "exec", it keeps its connection open and execs /bin/sleep, which holds the socket on.
//
// Every line goes to stdout, so a test reads what the process itself saw.

let environment = ProcessInfo.processInfo.environment
let loaderKeys = environment.keys.filter { $0.hasPrefix("DYLD_") }.sorted()

print("args: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
print("loader: \(loaderKeys.isEmpty ? "none" : loaderKeys.joined(separator: " "))")
print("directory: \(FileManager.default.currentDirectoryPath)")

/// The connection, kept open for "exec" mode.
nonisolated(unsafe) var kept: FramedSocket?

func answer() -> String {
  guard let path = environment["UNITERM_SOCKET"], !path.isEmpty else { return "no socket" }

  do {
    let socket = try UnixSocket.connect(path: path)

    kept = socket

    try socket.send(ScriptHelperMessage.hello(version: ScriptProtocol.version).frame())

    let hello = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    try ScriptAppMessage.validateHello(
      try ScriptAppMessage.decode(type: hello.type, body: hello.body))
    try socket.send(ScriptHelperMessage.begin(name: "native fixture").frame())
    try socket.send(ScriptHelperMessage.request(id: 1, call: .listWindows).frame())

    let frame = try socket.readFrame(limit: ScriptAppMessage.bodyLimit(type:))

    switch try ScriptAppMessage.decode(type: frame.type, body: frame.body) {
    case .reply(1, .ok): return "ok"
    case .reply(1, .failure(_, let text)): return "refused \(text)"
    default: return "unexpected"
    }
  } catch {
    return "failed \(error)"
  }
}

print("call: \(answer())")

if CommandLine.arguments.contains("exec"), let socket = kept {
  _ = fcntl(socket.rawDescriptor, F_SETFD, 0)
  print("execing")
  fflush(stdout)
  _ = execv("/bin/sleep", [strdup("/bin/sleep"), strdup("30"), nil])
}

// With "wait", the fixture stays until a signal ends it, so a test can signal the command's
// process and see the entry itself take the signal.
if CommandLine.arguments.contains("wait") {
  print("waiting")
  fflush(stdout)
  pause()
}

fflush(stdout)

exit(CommandLine.arguments.last.flatMap { Int32($0) } ?? 0)
