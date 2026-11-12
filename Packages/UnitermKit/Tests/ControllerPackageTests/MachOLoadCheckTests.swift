import ControllerTestSupport
import Foundation
import XCTest

@testable import ControllerPackage

/// The native load boundary: which libraries and search paths a packaged Mach-O may name. The
/// images are built here from load commands alone, since the check reads nothing else, and one real
/// executable that SwiftPM built is checked too.
final class MachOLoadCheckTests: XCTestCase {
  enum Command {
    case library(String)
    case weakLibrary(String)
    case rpath(String)
    case linker(String)
    case dyldEnvironment(String)
  }

  /// A thin arm64 Mach-O header followed by `commands`.
  static func image(_ commands: [Command]) -> Data {
    var body = Data()

    for command in commands {
      let (code, text): (UInt32, String)

      switch command {
      case .library(let path): (code, text) = (0xc, path)
      case .weakLibrary(let path): (code, text) = (0x8000_0018, path)
      case .rpath(let path): (code, text) = (0x8000_001c, path)
      case .linker(let path): (code, text) = (0xe, path)
      case .dyldEnvironment(let value): (code, text) = (0x27, value)
      }

      let offset: UInt32 = code == 0xc || code == 0x8000_0018 ? 24 : 12
      var string = Data(text.utf8) + Data([0])

      while (Int(offset) + string.count) % 8 != 0 { string.append(0) }

      let size = UInt32(Int(offset) + string.count)
      var command = Data()

      command.append(little: code)
      command.append(little: size)
      command.append(little: offset)
      command.append(Data(count: Int(offset) - 12))
      command.append(string)
      body.append(command)
    }

    var header = Data()

    header.append(little: UInt32(0xfeed_facf))
    header.append(little: UInt32(0x0100_000c))
    header.append(little: UInt32(0))
    header.append(little: UInt32(2))
    header.append(little: UInt32(commands.count))
    header.append(little: UInt32(body.count))
    header.append(little: UInt32(0))
    header.append(little: UInt32(0))

    return header + body
  }

  private func assertRefused(
    _ files: [String: Data], entry: String = "bin/tool", saying fragment: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try MachOLoadCheck.check(entry: entry, files: files), file: file, line: line
    ) { error in
      XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
    }
  }

  /// Catches a check that refuses an entry loading only system libraries and its own packaged
  /// library through each relative form dyld accepts.
  func testSystemLibrariesAndPackagedLibrariesAreAllowed() throws {
    let library = Self.image([.library("/usr/lib/libSystem.B.dylib")])
    let entry = Self.image([
      .linker("/usr/lib/dyld"), .library("/usr/lib/libSystem.B.dylib"),
      .library("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"),
      .library("@executable_path/../lib/one.dylib"), .library("@loader_path/../lib/two.dylib"),
      .rpath("@loader_path/../lib"), .rpath("/usr/lib/swift"), .library("@rpath/three.dylib"),
      .library("@rpath/libswiftCore.dylib"),
    ])

    XCTAssertNoThrow(
      try MachOLoadCheck.check(
        entry: "bin/tool",
        files: [
          "bin/tool": entry, "lib/one.dylib": library, "lib/two.dylib": library,
          "lib/three.dylib": library,
        ]))
  }

  /// Catches each way a load command can reach outside the package and the system.
  func testLoadPathsOutsideThePackageAndTheSystemAreRefused() {
    assertRefused(
      ["bin/tool": Self.image([.library("/opt/homebrew/lib/libz.dylib")])],
      saying: "loads /opt/homebrew/lib/libz.dylib, which is outside")
    assertRefused(
      ["bin/tool": Self.image([.weakLibrary("/Users/synthetic/evil.dylib")])],
      saying: "outside the package and the system")
    assertRefused(
      ["bin/tool": Self.image([.library("/usr/lib/../../Users/synthetic/evil.dylib")])],
      saying: "outside the package and the system")
    assertRefused(
      ["bin/tool": Self.image([.library("@executable_path/../../evil.dylib")])],
      saying: "outside the package and the system")
    assertRefused(
      ["bin/tool": Self.image([.rpath("/usr/local/lib"), .library("@rpath/x.dylib")])],
      saying: "searches /usr/local/lib for libraries")
    assertRefused(
      ["bin/tool": Self.image([.library("relative.dylib")])],
      saying: "loads relative.dylib, which is outside")
    assertRefused(
      ["bin/tool": Self.image([.library("@loader_path/missing.dylib")])],
      saying: "which the package does not hold")
    assertRefused(
      ["bin/tool": Self.image([.dyldEnvironment("DYLD_INSERT_LIBRARIES=/tmp/x.dylib")])],
      saying: "sets dyld environment variables")
    assertRefused(
      ["bin/tool": Self.image([.linker("/tmp/dyld")])], saying: "names the dynamic linker")
    assertRefused(
      ["bin/tool": Data("#!/bin/sh\necho substitute\n".utf8)],
      saying: "is not a 64-bit Mach-O file")
  }

  /// Catches a packaged library that is trusted without its own check, since dyld loads what it
  /// names too.
  func testAPackagedLibraryIsCheckedLikeTheEntry() {
    assertRefused(
      [
        "bin/tool": Self.image([.library("@loader_path/libinner.dylib")]),
        "bin/libinner.dylib": Self.image([.library("/opt/local/lib/libssl.dylib")]),
      ],
      saying: "bin/libinner.dylib loads /opt/local/lib/libssl.dylib")
  }

  /// Catches an `@rpath` library whose packaged copy goes unchecked because a system search path
  /// comes first. dyld falls back to the packaged copy when the system has no such file, so each
  /// packaged candidate is checked like the entry.
  func testEveryPackagedRpathCandidateIsChecked() {
    assertRefused(
      [
        "bin/tool": Self.image([
          .rpath("/usr/lib/swift"), .rpath("@loader_path/../lib"),
          .library("@rpath/libinner.dylib"),
        ]),
        "lib/libinner.dylib": Self.image([.library("/opt/evil/libssl.dylib")]),
      ],
      saying: "lib/libinner.dylib loads /opt/evil/libssl.dylib")
  }

  /// Catches a fat file whose other slice is never read, since dyld may pick either one.
  func testEverySliceOfAFatFileIsChecked() {
    let good = Self.image([.library("/usr/lib/libSystem.B.dylib")])
    let bad = Self.image([.library("/opt/evil.dylib")])
    var fat = Data()

    fat.append(big: UInt32(0xcafe_babe))
    fat.append(big: UInt32(2))

    let first = 8 + 2 * 20

    for (index, slice) in [good, bad].enumerated() {
      fat.append(big: UInt32(0x0100_000c))
      fat.append(big: UInt32(0))
      fat.append(big: UInt32(first + index * good.count.roundedUp))
      fat.append(big: UInt32(slice.count))
      fat.append(big: UInt32(0))
    }

    for slice in [good, bad] {
      fat.append(slice)
      fat.append(Data(count: slice.count.roundedUp - slice.count))
    }

    assertRefused(["bin/tool": fat], saying: "loads /opt/evil.dylib")
  }

  /// Catches a check that refuses the executable SwiftPM builds, which loads only system libraries
  /// and searches only beside itself.
  func testARealSwiftPMExecutablePasses() throws {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let fixture = try XCTUnwrap(bundle).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ControllerNativeFixture")
    let bytes = try Data(contentsOf: fixture)

    XCTAssertNoThrow(try MachOLoadCheck.check(entry: "bin/fixture", files: ["bin/fixture": bytes]))
  }
}

extension Int {
  fileprivate var roundedUp: Int { (self + 15) / 16 * 16 }
}

extension Data {
  fileprivate mutating func append(little value: UInt32) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }

  fileprivate mutating func append(big value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
