import Foundation
import Network
import Synchronization

/// A local HTTP server for tests, bound to the loopback address on a port the system picks.
///
/// A test starts one, aims a web view at `url(_:)`, and reads back what the page sent through
/// `requests`. The server answers each request with whatever the handler returns, then closes the
/// connection. It keeps no state between requests beyond the log.
///
/// The server speaks plain HTTP. A request that does not start like HTTP, such as the opening
/// bytes of a TLS handshake, is dropped at once. A client that tries HTTPS against it sees a server
/// that does not speak TLS, not a hang. A TLS mode with a self-signed identity adds a case to
/// `Mode`, and `parameters(for:)` is the only place that needs to learn it.
public final class FixtureServer: Sendable {
  public enum Mode: Sendable {
    case http
  }

  /// One request as the server read it. Header names are lowercased.
  public struct Request: Sendable, Equatable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data

    public var path: String {
      target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? target
    }
  }

  public struct Response: Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(
      status: Int = 200, headers: [(name: String, value: String)] = [], body: Data = Data()
    ) {
      self.status = status
      self.headers = headers
      self.body = body
    }

    public static func html(_ text: String, status: Int = 200) -> Response {
      Response(
        status: status, headers: [("Content-Type", "text/html; charset=utf-8")],
        body: Data(text.utf8))
    }

    public static func redirect(to location: String, status: Int = 303) -> Response {
      Response(status: status, headers: [("Location", location)])
    }

    /// A page with the given title and a body that carries the same text, so a test can tell pages
    /// apart by what the web view reports.
    public static func page(titled title: String, body: String = "") -> Response {
      html("<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>")
    }
  }

  public typealias Handler = @Sendable (Request) -> Response

  public let mode: Mode
  public let port: UInt16

  private let listener: NWListener
  private let core: Core

  private init(mode: Mode, listener: NWListener, core: Core, port: UInt16) {
    self.mode = mode
    self.listener = listener
    self.core = core
    self.port = port
  }

  /// Starts a server and returns once it listens. Throws when the listener cannot bind or start.
  public static func start(
    mode: Mode = .http, handler: @escaping Handler = { _ in .page(titled: "ok") }
  ) async throws -> FixtureServer {
    let listener = try NWListener(using: parameters(for: mode))
    let core = Core(handler: handler)
    let queue = DispatchQueue(label: "FixtureServer")

    listener.newConnectionHandler = { connection in
      core.accept(connection, on: queue)
    }

    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = Once(continuation)

      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          once.resume(returning: listener.port?.rawValue ?? 0)

        case .failed(let error):
          once.resume(throwing: error)

        case .cancelled:
          once.resume(throwing: CancellationError())

        default:
          break
        }
      }

      listener.start(queue: queue)
    }

    return FixtureServer(mode: mode, listener: listener, core: core, port: port)
  }

  /// A port nothing listens on. A socket binds one and closes at once, so a connection to it is
  /// refused.
  public static func closedPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)

    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0

    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }

    guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    return UInt16(bigEndian: address.sin_port)
  }

  /// Everything the server has read, in arrival order.
  public var requests: [Request] { core.requests }

  /// The URL of `path` on this server. The host is `127.0.0.1`.
  public func url(_ path: String = "/") -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
  }

  /// The address as a person types it, with no scheme.
  public func address(_ path: String = "/") -> String {
    "127.0.0.1:\(port)\(path)"
  }

  public func stop() {
    listener.cancel()
  }

  private static func parameters(for mode: Mode) -> NWParameters {
    let parameters: NWParameters

    switch mode {
    case .http:
      parameters = NWParameters.tcp
    }

    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    return parameters
  }
}

/// Resumes a continuation once, whichever state change comes first.
private final class Once<Value: Sendable>: Sendable {
  private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

  init(_ continuation: CheckedContinuation<Value, any Error>) {
    self.continuation = Mutex(continuation)
  }

  func resume(returning value: Value) {
    take()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Value, any Error>? {
    continuation.withLock { held in
      defer { held = nil }
      return held
    }
  }
}

private final class Core: Sendable {
  private let handler: FixtureServer.Handler
  private let log = Mutex<[FixtureServer.Request]>([])

  init(handler: @escaping FixtureServer.Handler) {
    self.handler = handler
  }

  var requests: [FixtureServer.Request] { log.withLock { $0 } }

  func accept(_ connection: NWConnection, on queue: DispatchQueue) {
    connection.start(queue: queue)
    receive(on: connection, held: Data())
  }

  private func receive(on connection: NWConnection, held: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [self] data, _, isComplete, error in
      var buffer = held

      if let data { buffer.append(data) }

      if let first = buffer.first, !(0x41...0x5A).contains(first) {
        connection.cancel()
        return
      }

      if let request = Self.parse(buffer) {
        log.withLock { $0.append(request) }
        send(handler(request), on: connection)
        return
      }

      if error != nil || isComplete {
        connection.cancel()
        return
      }

      receive(on: connection, held: buffer)
    }
  }

  private func send(_ response: FixtureServer.Response, on connection: NWConnection) {
    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"

    for header in response.headers {
      head += "\(header.name): \(header.value)\r\n"
    }

    head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"

    connection.send(
      content: Data(head.utf8) + response.body, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  /// Reads one request once its head and its declared body have arrived. Nil means more bytes are
  /// needed.
  static func parse(_ buffer: Data) -> FixtureServer.Request? {
    let separator = Data("\r\n\r\n".utf8)

    guard let end = buffer.range(of: separator) else { return nil }

    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let start = lines.removeFirst().split(separator: " ")

    guard start.count >= 2 else { return nil }

    var headers: [String: String] = [:]

    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }

      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    let length = headers["content-length"].flatMap { Int($0) } ?? 0
    let body = buffer[end.upperBound...]

    guard body.count >= length else { return nil }

    return FixtureServer.Request(
      method: String(start[0]), target: String(start[1]), headers: headers,
      body: Data(body.prefix(length)))
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 303: return "See Other"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "Status"
    }
  }
}
