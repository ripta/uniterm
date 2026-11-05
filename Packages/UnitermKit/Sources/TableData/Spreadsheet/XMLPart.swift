import Foundation
import ZIPFoundation

/// The thread a ZIP part is inflated on. The archive is touched by one thread at a time, because
/// the loader waits for the producer before it reads the archive again.
final class ArchiveBox: @unchecked Sendable {
  let archive: Archive

  init(_ archive: Archive) {
    self.archive = archive
  }
}

/// What the inflating thread tells the thread that parses.
final class XMLPump: @unchecked Sendable {
  private let lock = NSLock()
  private var inflated = 0
  private var stored: SpreadsheetFailure?
  private var stopRequested = false

  /// Bytes inflated so far from the part being read.
  var inflatedBytes: Int { lock.withLock { inflated } }

  var failure: SpreadsheetFailure? { lock.withLock { stored } }

  /// True once the parser has stopped listening. Writing to a closed pipe does not fail, so the
  /// inflating thread checks this between chunks, or it would inflate the rest of the part for
  /// nothing.
  var isStopRequested: Bool { lock.withLock { stopRequested } }

  func requestStop() {
    lock.withLock { stopRequested = true }
  }

  func add(_ count: Int) -> Int {
    lock.withLock {
      inflated += count
      return inflated
    }
  }

  func fail(_ failure: SpreadsheetFailure) {
    lock.withLock {
      if stored == nil { stored = failure }
    }
  }
}

/// A base for the XML readers. It counts nesting, refuses entity declarations, checks for a cancel,
/// and strips namespace prefixes. A subclass overrides `begin`, `end`, and `text`.
///
/// A reader never sees an entity declaration. The producer refuses a document type declaration
/// before the parser gets the bytes, and the callbacks below refuse any that slip through, such as
/// in a UTF-16 document. So no entity expands beyond the five that XML predefines.
class XMLHandler: NSObject, XMLParserDelegate {
  var failure: SpreadsheetFailure?
  var isCancelled: () -> Bool = { false }
  var maxDepth = SpreadsheetLimits.standard.depth

  private(set) var depth = 0
  private(set) var rootName: String?
  private var events = 0
  private weak var parser: XMLParser?

  /// Tells the inflating thread to stop. Aborting a parse does not end it. `XMLParser` reads the
  /// rest of the stream and throws it away, so the producer has to stop first.
  var onStop: (() -> Void)?

  func attach(_ parser: XMLParser) {
    self.parser = parser
  }

  /// Stops the parse. The first failure wins.
  func stop(_ reason: SpreadsheetFailure) {
    if failure == nil { failure = reason }

    onStop?()
    parser?.abortParsing()
  }

  func begin(_ name: String, _ attributes: [String: String]) {}

  func end(_ name: String) {}

  func text(_ characters: String) {}

  private func local(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name }

    return String(name[name.index(after: colon)...])
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    depth += 1
    events += 1

    if depth > maxDepth {
      stop(.tooLarge("its XML nests deeper than \(maxDepth) levels"))
      return
    }

    if events & 0x3FF == 0, isCancelled() {
      stop(.cancelled)
      return
    }

    let name = local(elementName)

    if rootName == nil { rootName = name }

    begin(name, attributeDict)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    depth -= 1
    end(local(elementName))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text(string)
  }

  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    text(String(decoding: block, as: UTF8.self))
  }

  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) {
    stop(.invalid("it declares XML entities, which a workbook never does"))
  }

  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?
  ) {
    stop(.invalid("it declares XML entities, which a workbook never does"))
  }

  func parser(
    _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
    systemID: String?, notationName: String?
  ) {
    stop(.invalid("it declares XML entities, which a workbook never does"))
  }
}

/// Spots `<!DOCTYPE` and `<!ENTITY` across chunk boundaries. A comment starts `<!-`, and character
/// data starts `<![`, so neither trips it.
struct DeclarationScan {
  private var state = 0

  mutating func sees(_ chunk: Data) -> Bool {
    chunk.withUnsafeBytes { bytes in
      for byte in bytes {
        switch state {
        case 0:
          if byte == 0x3C { state = 1 }

        case 1:
          state = byte == 0x21 ? 2 : (byte == 0x3C ? 1 : 0)

        default:
          if byte == 0x44 || byte == 0x45 { return true }

          state = byte == 0x3C ? 1 : 0
        }
      }

      return false
    }
  }
}

/// The work of the inflating thread. One thread runs it, and the loader waits on `finished`
/// before it touches the archive or the stream again.
final class InflateJob: @unchecked Sendable {
  let finished = DispatchSemaphore(value: 0)

  private let box: ArchiveBox
  private let entry: Entry
  private let output: OutputStream
  private let name: String
  private let cap: Int
  private let capMessage: String
  private let pump: XMLPump
  private let observe: (@Sendable (Int) -> Void)?

  init(
    box: ArchiveBox, entry: Entry, output: OutputStream, name: String, cap: Int,
    capMessage: String, pump: XMLPump, observe: (@Sendable (Int) -> Void)?
  ) {
    self.box = box
    self.entry = entry
    self.output = output
    self.name = name
    self.cap = cap
    self.capMessage = capMessage
    self.pump = pump
    self.observe = observe
  }

  func run() {
    var scan = DeclarationScan()
    var empties = 0

    do {
      let checksum = try box.archive.extract(entry, bufferSize: XMLPart.chunkSize) { chunk in
        if pump.isStopRequested { throw SpreadsheetFailure.consumerGone }

        if chunk.isEmpty {
          empties += 1

          if empties > 1 {
            throw SpreadsheetFailure.invalid("\(name) is shorter than the archive says")
          }

          return
        }

        empties = 0

        if pump.add(chunk.count) > cap { throw SpreadsheetFailure.tooLarge(capMessage) }

        observe?(chunk.count)

        if scan.sees(chunk) {
          throw SpreadsheetFailure.invalid("it declares XML entities, which a workbook never does")
        }

        try write(chunk)
      }

      // Checked after the last chunk, so a flipped byte that still parses fails the load with a
      // message instead of showing a wrong value.
      if checksum != entry.checksum {
        throw SpreadsheetFailure.invalid(
          "the data in \(name) is corrupt, since its checksum does not match")
      }
    } catch let failure as SpreadsheetFailure {
      pump.fail(failure)
    } catch {
      pump.fail(.invalid("\(name) cannot be inflated"))
    }

    output.close()
    finished.signal()
  }

  private func write(_ chunk: Data) throws {
    try chunk.withUnsafeBytes { bytes in
      var written = 0

      while written < bytes.count {
        let count = output.write(
          bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + written,
          maxLength: bytes.count - written)

        if count <= 0 { throw SpreadsheetFailure.consumerGone }

        written += count
      }
    }
  }
}

enum XMLPart {
  /// Bytes the producer inflates in one step, and the size of the pipe to the parser.
  static let chunkSize = 64 << 10

  /// Inflates one ZIP entry on a second thread and parses it as it arrives. Nothing buffers more
  /// than the pipe holds, so a part of any size costs the same memory.
  ///
  /// The cap counts bytes that were actually inflated. The size in the archive's directory is
  /// never read, since a hostile file lies about it. The producer stops the moment the count
  /// passes the cap, and the parser then ends on a truncated document.
  static func parse(
    _ entry: Entry, in box: ArchiveBox, name: String, cap: Int, capMessage: String,
    limits: SpreadsheetLimits, pump: XMLPump = XMLPump(), handler: XMLHandler
  ) throws {
    var input: InputStream?
    var output: OutputStream?

    Stream.getBoundStreams(
      withBufferSize: chunkSize, inputStream: &input, outputStream: &output)

    guard let input, let output else {
      throw SpreadsheetFailure.invalid("the system could not open a stream to read \(name)")
    }

    output.open()

    let job = InflateJob(
      box: box, entry: entry, output: output, name: name, cap: cap, capMessage: capMessage,
      pump: pump, observe: limits.observeChunk)

    let thread = Thread { job.run() }

    thread.name = "uniterm.xlsx.inflate"
    thread.stackSize = 1 << 20
    thread.start()

    let parser = XMLParser(stream: input)
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.delegate = handler
    handler.attach(parser)
    handler.onStop = { pump.requestStop() }

    let parsed = parser.parse()

    pump.requestStop()
    input.close()
    job.finished.wait()

    if let failure = handler.failure { throw failure }

    if let failure = pump.failure, failure != .consumerGone { throw failure }

    if !parsed {
      throw SpreadsheetFailure.invalid(
        "the XML in \(name) is not well formed, near line \(parser.lineNumber)")
    }
  }
}
