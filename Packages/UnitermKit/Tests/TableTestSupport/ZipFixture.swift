import Compression
import Foundation

/// Builds ZIP archives in code, since the repo holds no binary fixtures. Every test target that
/// needs an archive uses this one writer.
public enum ZipMethod {
  case stored
  case deflate
}

public struct ZipPart {
  public var name: String
  public var data: [UInt8]
  public var method = ZipMethod.deflate

  /// The size the directory claims, when a test needs it to lie.
  public var claimedSize: UInt32?

  public init(_ name: String, _ text: String, method: ZipMethod = .deflate) {
    self.name = name
    data = Array(text.utf8)
    self.method = method
  }

  public init(
    _ name: String, bytes: [UInt8], method: ZipMethod = .deflate, claimedSize: UInt32? = nil
  ) {
    self.name = name
    data = bytes
    self.method = method
    self.claimedSize = claimedSize
  }
}

public enum ZipFixture {
  public static func archive(_ parts: [ZipPart]) -> [UInt8] {
    var file: [UInt8] = []
    var directory: [UInt8] = []

    for part in parts {
      let name = Array(part.name.utf8)
      var body = part.data
      var method: UInt16 = 0

      if part.method == .deflate, let packed = deflate(part.data) {
        body = packed
        method = 8
      }

      let crc = crc32(part.data)
      let claimed = part.claimedSize ?? UInt32(part.data.count)
      let offset = UInt32(file.count)

      file += le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21)
      file += le32(crc) + le32(UInt32(body.count)) + le32(claimed) + le16(UInt16(name.count))
      file += le16(0) + name + body

      directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0)
      directory += le16(0x21) + le32(crc) + le32(UInt32(body.count)) + le32(claimed)
      directory += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
      directory += le32(offset) + name
    }

    let start = UInt32(file.count)

    return file + directory + le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(parts.count))
      + le16(UInt16(parts.count)) + le32(UInt32(directory.count)) + le32(start) + le16(0)
  }

  /// Reads back an archive that `archive` wrote, so a seed can be taken apart and mutated.
  public static func parts(of archive: [UInt8]) -> [ZipPart]? {
    func u16(_ at: Int) -> Int { Int(archive[at]) | Int(archive[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

    guard archive.count >= 22 else { return nil }

    let end = archive.count - 22
    var offset = u32(end + 16)
    var parts: [ZipPart] = []

    for _ in 0..<u16(end + 10) {
      let method = u16(offset + 10)
      let packed = u32(offset + 20)
      let size = u32(offset + 24)
      let nameLength = u16(offset + 28)
      let local = u32(offset + 42)
      let name = String(
        decoding: archive[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
      let data = local + 30 + u16(local + 26) + u16(local + 28)
      let body = Array(archive[data..<(data + packed)])

      var text = body

      if method == 8 {
        var output = [UInt8](repeating: 0, count: max(size, 1))
        let count = compression_decode_buffer(
          &output, output.count, body, body.count, nil, COMPRESSION_ZLIB)
        text = Array(output[0..<count])
      }

      parts.append(ZipPart(name, bytes: text, method: method == 8 ? .deflate : .stored))
      offset += 46 + nameLength
    }

    return parts
  }

  public static func deflate(_ bytes: [UInt8]) -> [UInt8]? {
    guard !bytes.isEmpty else { return nil }

    let capacity = bytes.count + 4_096
    var output = [UInt8](repeating: 0, count: capacity)

    let count = compression_encode_buffer(
      &output, capacity, bytes, bytes.count, nil, COMPRESSION_ZLIB)

    return count > 0 ? Array(output[0..<count]) : nil
  }

  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)

    for _ in 0..<8 {
      value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }

    return value
  }

  public static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var value: UInt32 = 0xFFFF_FFFF

    for byte in bytes {
      value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
    }

    return value ^ 0xFFFF_FFFF
  }

  public static func le16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8)]
  }

  public static func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
  }
}
