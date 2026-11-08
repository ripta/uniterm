import Foundation
import TableTestSupport
import XCTest

@testable import ImageWire

/// A seeded mutation fuzzer for the wire codec as shipped. Each input is a valid frame with bytes
/// flipped, cut, or inserted, and goes through the same decoders and checks the app applies to
/// helper bytes.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer at
/// a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated frame traps or reads out of bounds in uniterm's codec, and that an
/// image the checks accept always has exactly the bytes its dimensions call for. It cannot prove the
/// helper behaves.
final class ImageWireFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x1A6E
  }

  private func corpus() -> [Data] {
    let header = ImageHeader(
      request: 4, source: 2, frame: 0, width: 5, height: 3, space: .sRGB, format: .rgba8)

    return [
      HelperMessage.hello(version: 1, types: ["public.png", "public.jpeg", "public.heic"]).frame(),
      HelperMessage.opened(
        SourceInfo(
          source: 2, width: 40, height: 30, frameDelays: [100, 120], dpiX: 144, dpiY: 144)
      ).frame(),
      AppMessage.region(request: 4, source: 2, level: 40, x: 0, y: 8, width: 16, height: 16)
        .frame(),
      AppMessage.release(source: 2).frame(),
      HelperMessage.image(header, pixels: Data(repeating: 7, count: 60)).frame(),
      HelperMessage.failure(request: 4, kind: .limit, text: "Past the limit.").frame(),
      HelperMessage.pong(nonce: 9).frame(),
    ]
  }

  /// Catches a mutated frame that traps the decoder, or an image that passes the app's checks with
  /// pixels that do not match its dimensions.
  func testMutatedFramesDecodeWithoutTrappingAndAcceptedImagesAreExactlySized() {
    var random = SplitMix64(seed: seed)
    let inputs = corpus()
    let expectation = ImageExpectation(
      request: 4, source: 2, frame: 0, maxPixel: 8, sourceWidth: 40, sourceHeight: 30,
      byteCap: 1 << 16)
    let region = ImageExpectation(
      request: 4, source: 2, frame: 0, maxPixel: 40, sourceWidth: 40, sourceHeight: 30,
      byteCap: 1 << 16, region: (8, 6))
    var accepted = 0

    for iteration in 0..<iterations {
      var frame = [UInt8](inputs[Int(random.next() % UInt64(inputs.count))])

      for _ in 0..<Int(1 + random.next() % 4) {
        mutate(&frame, using: &random)
      }

      let context = "seed \(seed), iteration \(iteration), frame \(frame)"

      guard frame.count >= FrameHeader.size,
        let (type, length) = try? FrameHeader.parse(Data(frame.prefix(FrameHeader.size)))
      else { continue }

      let body = Data(frame.dropFirst(FrameHeader.size).prefix(max(length, 0)))

      guard let message = try? HelperMessage.decode(type: type, body: body) else { continue }

      if case .image(let header, let pixels) = message,
        (try? expectation.validate(header, pixels: pixels)) != nil
      {
        accepted += 1

        let format = header.space.format
        let expected = ImageLimits.byteCount(
          width: Int(header.width), height: Int(header.height), format: format)

        XCTAssertEqual(pixels.count, expected, context)
        XCTAssertLessThanOrEqual(max(header.width, header.height), 8, context)
      }

      if case .image(let header, let pixels) = message,
        (try? region.validate(header, pixels: pixels)) != nil
      {
        let expected = ImageLimits.byteCount(
          width: Int(header.width), height: Int(header.height), format: header.space.format)

        XCTAssertEqual(pixels.count, expected, context)
        XCTAssertLessThanOrEqual(header.width, 8, context)
        XCTAssertLessThanOrEqual(header.height, 6, context)
      }

      _ = try? AppMessage.decode(type: type, body: body)
    }

    if iterations >= 200 { XCTAssertGreaterThan(accepted, 0) }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 5 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80][Int(random.next() % 4)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    default: bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: Int(random.next() % 16)))
    }
  }
}
