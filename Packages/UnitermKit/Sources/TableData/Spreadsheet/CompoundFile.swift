import Darwin
import Foundation

/// Tells apart the files that share the old Office container. A legacy `.xls` workbook is a
/// compound file. So is a password-protected `.xlsx`, which holds the encrypted package as a
/// stream. Only the directory is read, never the streams.
///
/// Every read is bounded. A hostile header cannot make the walk loop, and a file that does not read
/// as a compound file is named as a legacy workbook, which is what the extension usually means.
enum CompoundFile {
  static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

  private static let endOfChain: UInt32 = 0xFFFF_FFFE
  private static let maxSectors = 1 << 20
  private static let maxDirectorySectors = 4_096

  /// What the compound file at `descriptor` is.
  static func classify(_ descriptor: Int32, fileSize: Int) -> UnsupportedSpreadsheet {
    guard let names = streamNames(descriptor, fileSize: fileSize) else { return .legacyXLS }

    if names.contains("EncryptedPackage") || names.contains("EncryptionInfo") {
      return .passwordProtected
    }

    if names.contains("Workbook") || names.contains("Book") || names.isEmpty {
      return .legacyXLS
    }

    return .otherOfficeFile
  }

  private static func read(_ descriptor: Int32, at offset: Int, count: Int) -> [UInt8]? {
    guard offset >= 0, count > 0 else { return nil }

    var bytes = [UInt8](repeating: 0, count: count)
    var done = 0

    while done < count {
      let got = bytes.withUnsafeMutableBytes { buffer in
        pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset + done))
      }

      if got < 0, errno == EINTR { continue }
      if got <= 0 { return nil }

      done += got
    }

    return bytes
  }

  private static func u16(_ bytes: [UInt8], _ at: Int) -> Int {
    Int(bytes[at]) | Int(bytes[at + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
      | UInt32(bytes[at + 3]) << 24
  }

  /// The names of the directory's entries, or nil unless the walk reaches the end of the chain.
  private static func streamNames(_ descriptor: Int32, fileSize: Int) -> Set<String>? {
    guard let header = read(descriptor, at: 0, count: 512) else { return nil }

    let shift = u16(header, 30)

    guard shift == 9 || shift == 12 else { return nil }

    let sectorSize = 1 << shift
    let perSector = sectorSize / 4
    let sectorCount = max(0, (fileSize - sectorSize) / sectorSize)

    func offset(of sector: UInt32) -> Int? {
      Int(sector) < min(sectorCount, maxSectors) ? (Int(sector) + 1) * sectorSize : nil
    }

    var fat: [UInt32] = []
    let fatCount = Int(min(u32(header, 44), UInt32(maxSectors)))

    for index in 0..<109 where fat.count < fatCount {
      fat.append(u32(header, 76 + index * 4))
    }

    var difat = u32(header, 68)
    var difatSteps = 0

    while fat.count < fatCount, difat != endOfChain, difatSteps < maxSectors {
      guard let at = offset(of: difat), let sector = read(descriptor, at: at, count: sectorSize)
      else { return nil }

      for index in 0..<(perSector - 1) where fat.count < fatCount {
        fat.append(u32(sector, index * 4))
      }

      difat = u32(sector, (perSector - 1) * 4)
      difatSteps += 1
    }

    func next(after sector: UInt32) -> UInt32? {
      let table = Int(sector) / perSector

      guard table < fat.count, let at = offset(of: fat[table]),
        let bytes = read(descriptor, at: at + Int(sector) % perSector * 4, count: 4)
      else { return nil }

      return u32(bytes, 0)
    }

    var names: Set<String> = []
    var sector = u32(header, 48)
    var steps = 0

    while sector != endOfChain, steps < maxDirectorySectors {
      guard let at = offset(of: sector), let bytes = read(descriptor, at: at, count: sectorSize)
      else { return nil }

      for entry in stride(from: 0, to: sectorSize, by: 128) {
        let length = u16(bytes, entry + 64)

        guard length >= 2, length <= 64, bytes[entry + 66] != 0 else { continue }

        let units = (0..<(length / 2 - 1)).map {
          UInt16(bytes[entry + $0 * 2]) | UInt16(bytes[entry + $0 * 2 + 1]) << 8
        }

        names.insert(String(decoding: units, as: UTF16.self))
      }

      guard let following = next(after: sector) else { return nil }

      sector = following
      steps += 1
    }

    return sector == endOfChain ? names : nil
  }
}
