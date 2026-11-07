import Darwin
import Dispatch
import Foundation
import ImageIO
import ImageWire

/// Serves the decode-only protocol on a socket until the app closes it.
///
/// The thread that calls `run` reads messages and answers pings at once. Opens and decodes go to
/// one serial queue, so a decode that spins never stops the pong the app uses to tell a slow
/// decode from a stopped helper.
public final class ImageHelperServer: @unchecked Sendable {
  private let socket: FramedSocket
  private let types: [String]
  private let queue = DispatchQueue(label: "uniterm.image-decoder.work")

  private var current: OpenedImage?
  private var fault: String?

  /// Serves on `socket`. Tests pass `types` to shorten the list.
  public init(socket: FramedSocket, types: [String]? = nil) {
    self.socket = socket
    self.types = types ?? Self.imageTypes()
  }

  static func imageTypes() -> [String] {
    let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []

    return identifiers.filter { $0.utf8.count <= ImageLimits.maxTypeBytes }
      .prefix(ImageLimits.maxTypes).map { $0 }
  }

  /// Reads until the socket closes. Returns the process exit status.
  public func run() -> Int32 {
    guard
      (try? socket.send(HelperMessage.hello(version: ImageProtocol.version, types: types).frame()))
        != nil
    else { return 1 }

    while true {
      let frame: (type: UInt8, body: Data)

      do {
        frame = try socket.readFrame { _ in ImageProtocol.maxControlBody }
      } catch WireError.closed {
        return 0
      } catch {
        return 2
      }

      guard let message = try? AppMessage.decode(type: frame.type, body: frame.body) else {
        return 3
      }

      switch message {
      case .hello(let version):
        guard version == ImageProtocol.version else { return 4 }

      case .ping(let nonce):
        _ = try? socket.send(HelperMessage.pong(nonce: nonce).frame())

      case .open(let source):
        let descriptor = socket.takeDescriptor()

        queue.async { [self] in open(source: source, descriptor: descriptor) }

      case .decode(let request, let source, let maxPixel, let frame):
        queue.async { [self] in
          decode(request: request, source: source, maxPixel: Int(maxPixel), frame: Int(frame))
        }
      }
    }
  }

  private func reply(_ message: HelperMessage) {
    _ = try? socket.send(message.frame())
  }

  private func open(source: UInt32, descriptor: Int32?) {
    current = nil
    fault = nil

    guard let descriptor else {
      reply(.failure(request: 0, kind: .noSource, text: "No file came with the open request."))
      return
    }

    do {
      let mapping = try FileMapping(descriptor: descriptor)

      #if DEBUG
        if let kind = FaultInjection.fault(in: mapping.data) {
          fault = kind
          reply(.opened(SourceInfo(source: source, width: 100, height: 100, frameDelays: [0])))
          return
        }
      #endif

      let opened = try OpenedImage(mapping: mapping, sourceID: source)
      current = opened
      reply(.opened(opened.info))
    } catch let error as SourceFailure {
      reply(.failure(request: 0, kind: kind(of: error), text: error.text))
    } catch {
      reply(.failure(request: 0, kind: .unreadable, text: "The file could not be opened."))
    }
  }

  private func decode(request: UInt32, source: UInt32, maxPixel: Int, frame: Int) {
    #if DEBUG
      if let fault {
        FaultInjection.perform(fault)
      }
    #endif

    guard let image = current, image.info.source == source else {
      reply(.failure(request: request, kind: .staleSource, text: "The source was replaced."))
      return
    }

    guard frame >= 0, frame < image.info.frameCount else {
      reply(.failure(request: request, kind: .unreadable, text: "The frame does not exist."))
      return
    }

    do {
      let rendered = try PixelRenderer.render(image, frame: frame, maxPixel: maxPixel)
      let header = ImageHeader(
        request: request, source: source, frame: UInt32(frame), width: UInt32(rendered.width),
        height: UInt32(rendered.height), space: rendered.space, format: rendered.space.format)

      let parts = HelperMessage.imageParts(header, pixels: rendered.pixels)

      _ = try? socket.send(prefix: parts.prefix, trailer: parts.pixels)
    } catch let error as SourceFailure {
      reply(.failure(request: request, kind: kind(of: error), text: error.text))
    } catch {
      reply(.failure(request: request, kind: .unreadable, text: "The image could not be decoded."))
    }
  }

  private func kind(of error: SourceFailure) -> FailureKind {
    switch error.kind {
    case .unsupported: return .unsupportedFormat
    case .unreadable: return .unreadable
    case .limit: return .limit
    }
  }
}
