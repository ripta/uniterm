import ControllerPackage
import Foundation
import TableTestSupport
import XCTest

@testable import ControllerTrust

/// A seeded mutation fuzzer for the policy file reader. Each input is a valid file with bytes
/// flipped, cut, or inserted.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated file traps the reader, and that a file that reads writes back to
/// bytes that read the same. It cannot prove that a refusal names the right fault, which the
/// format tests hold.
final class ControllerPolicyFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 400
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x7_0115
  }

  /// Catches a mutated policy file that traps the reader, or one whose rewrite reads differently.
  func testMutatedPolicyFilesReadWithoutTrapping() throws {
    var random = SplitMix64(seed: seed)
    let seedFile = ControllerPolicyFile.encode([
      ControllerPolicy(
        selector: .version(
          controllerID: "dev.uniterm.fixture.fuzz", version: String(repeating: "0f", count: 32)),
        name: "Fuzz",
        scopes: [
          .paneControl, .clipboardRead, .clipboardWrite, .capability("fs-read"),
          .hostLaunch(
            try HostLaunchScope(executable: "/bin/echo", directory: "/tmp", environmentKeys: ["K"])),
        ], approved: "2026-11-11T10:00:00Z"),
      ControllerPolicy(
        selector: .identity(
          controllerID: "dev.uniterm.fixture.fuzz",
          keyFingerprint: String(repeating: "e", count: 64)),
        name: "Fuzz", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z"),
    ])

    for iteration in 0..<iterations {
      var bytes = [UInt8](seedFile)

      for _ in 0..<Int(random.next() % 4) { mutate(&bytes, using: &random) }

      guard let policies = try? ControllerPolicyFile.decode(Data(bytes)) else { continue }

      XCTAssertEqual(
        Set(try ControllerPolicyFile.decode(ControllerPolicyFile.encode(policies))), Set(policies),
        "seed \(seed), iteration \(iteration)")
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 5 {
    case 0: bytes[at] ^= UInt8(truncatingIfNeeded: random.next())
    case 1: bytes[at] = [0, 0xFF, 0x7F, 0x80, 0x22, 0x5C, 0x31][Int(random.next() % 7)]
    case 2: bytes.removeSubrange(at..<min(bytes.count, at + 1 + Int(random.next() % 8)))
    case 3: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    default: bytes.append(contentsOf: [UInt8](repeating: 0x20, count: Int(random.next() % 16)))
    }
  }
}
