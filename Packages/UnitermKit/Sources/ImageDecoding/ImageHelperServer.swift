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

  private var opened: [UInt32: OpenedImage] = [:]
  private var faults: [UInt32: String] = [:]

  /// Source IDs from the one used longest ago to the one used last.
  private var used: [UInt32] = []

  /// The decode the last region request asked for, which later regions of the same level cut from.
  /// Only one is kept, so the helper holds at most one decode beyond the sources it has open.
  private var level: Level?

  private struct Level {
    var source: UInt32
    var maxPixel: Int
    var image: RenderedImage
  }

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

      case .region(let request, let source, let level, let x, let y, let width, let height):
        queue.async { [self] in
          region(
            request: request, source: source, maxPixel: Int(level),
            rect: (Int(x), Int(y), Int(width), Int(height)))
        }

      case .release(let source):
        queue.async { [self] in
          if level?.source == source { level = nil }
        }
      }
    }
  }

  private func reply(_ message: HelperMessage) {
    _ = try? socket.send(message.frame())
  }

  private func forget(_ source: UInt32) {
    if level?.source == source { level = nil }

    opened[source] = nil
    faults[source] = nil
    used.removeAll { $0 == source }
  }

  private func remember(_ source: UInt32) {
    used.removeAll { $0 == source }
    used.append(source)

    while used.count > ImageProtocol.retainedSources, let oldest = used.first {
      forget(oldest)
    }
  }

  private func open(source: UInt32, descriptor: Int32?) {
    forget(source)

    guard let descriptor else {
      reply(.failure(request: 0, kind: .noSource, text: "No file came with the open request."))
      return
    }

    do {
      let mapping = try FileMapping(descriptor: descriptor)

      #if DEBUG
        if let kind = FaultInjection.fault(in: mapping.data) {
          faults[source] = kind
          remember(source)
          reply(.opened(SourceInfo(source: source, width: 100, height: 100, frameDelays: [0])))
          return
        }
      #endif

      let image = try OpenedImage(mapping: mapping, sourceID: source)
      opened[source] = image
      remember(source)
      reply(.opened(image.info))
    } catch let error as SourceFailure {
      reply(.failure(request: 0, kind: kind(of: error), text: error.text))
    } catch {
      reply(.failure(request: 0, kind: .unreadable, text: "The file could not be opened."))
    }
  }

  private func decode(request: UInt32, source: UInt32, maxPixel: Int, frame: Int) {
    #if DEBUG
      if let fault = faults[source] {
        FaultInjection.perform(fault)
      }
    #endif

    guard let image = opened[source] else {
      reply(.failure(request: request, kind: .staleSource, text: "The source was replaced."))
      return
    }

    remember(source)

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

  /// Answers with a rectangle of the decode at `maxPixel`. The decode is made once and kept, so a
  /// pan costs a copy. The old decode goes first, so two large ones never exist together.
  private func region(request: UInt32, source: UInt32, maxPixel: Int, rect: (Int, Int, Int, Int)) {
    guard let image = opened[source] else {
      reply(.failure(request: request, kind: .staleSource, text: "The source was replaced."))
      return
    }

    #if DEBUG
      if let fault = faults[source] ?? image.regionFault {
        FaultInjection.perform(fault)
      }
    #endif

    remember(source)

    do {
      if level?.source != source || level?.maxPixel != maxPixel {
        level = nil

        let exact = LevelGeometry.size(
          nativeWidth: Int(image.info.width), nativeHeight: Int(image.info.height),
          longerSide: maxPixel)
        let rendered = try PixelRenderer.render(
          image, frame: 0, maxPixel: maxPixel, exactSize: exact)

        level = Level(source: source, maxPixel: maxPixel, image: rendered)
      }

      guard let held = level?.image,
        let cut = PixelRenderer.crop(
          held, x: rect.0, y: rect.1, width: rect.2, height: rect.3)
      else {
        reply(
          .failure(request: request, kind: .unreadable, text: "The region is outside the image."))
        return
      }

      let header = ImageHeader(
        request: request, source: source, frame: 0, width: UInt32(cut.width),
        height: UInt32(cut.height), space: cut.space, format: cut.space.format)
      let parts = HelperMessage.imageParts(header, pixels: cut.pixels)

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
