import FileRouting
import XCTest

final class OpenAuthorityTests: XCTestCase {
  private func sender(opener: String?, identifier: String? = "com.example.launcher")
    -> SenderIdentity
  {
    SenderIdentity(
      pid: 9, pidVersion: 1, signingIdentifier: identifier, teamIdentifier: "TEAM",
      isPlatformBinary: false, isAppleAnchored: false, opener: opener)
  }

  /// Catches an authority that trusts a sender it should refuse, or refuses the user's own act.
  func testOnlyAnAppleOpenerIsTheUsersAct() {
    XCTAssertEqual(
      OpenAuthority.decide(for: sender(opener: "Finder")), .userAct(opener: "Finder"))
    XCTAssertEqual(
      OpenAuthority.decide(for: sender(opener: nil)), .refused(sender: "com.example.launcher"))
    XCTAssertEqual(OpenAuthority.decide(for: nil), .refused(sender: "an unidentified program"))
  }

  /// Catches a message that names a sender by a control character or an unbounded string. The name
  /// comes from the signing identifier, which the signer chooses.
  func testASenderNameIsPrintableAndBounded() {
    let hostile = "a\u{1B}[2Jb\n" + String(repeating: "x", count: 500)
    let name = sender(opener: nil, identifier: hostile).name

    XCTAssertFalse(name.contains("\u{1B}"))
    XCTAssertFalse(name.contains("\n"))
    XCTAssertLessThanOrEqual(name.count, SenderIdentity.longestName + 1)
  }

  func testAnUnsignedSenderIsNamedByItsProcess() {
    XCTAssertEqual(
      sender(opener: nil, identifier: nil).name, "an unsigned program (process 9)")
  }

  // MARK: Coalescing

  /// Catches a loop of refused opens that posts a message each time. A thousand refusals inside
  /// one interval post exactly one, naming the first sender.
  func testALoopOfRefusalsPostsOneMessagePerInterval() {
    var coalescer = RefusalCoalescer(interval: 30)
    var posted: [String] = []

    for index in 0..<1000 {
      if let text = coalescer.note(sender: "com.example.\(index)", at: Double(index) * 0.01) {
        posted.append(text)
      }
    }

    XCTAssertEqual(posted.count, 1)
    XCTAssertTrue(posted[0].contains("com.example.0"))
  }

  /// Catches a coalescer that stays silent forever, or loses the count of what it folded.
  func testTheNextIntervalPostsAgainAndCountsTheFoldedOpens() {
    var coalescer = RefusalCoalescer(interval: 30)

    XCTAssertNotNil(coalescer.note(sender: "a", at: 0))
    XCTAssertNil(coalescer.note(sender: "a", at: 1))
    XCTAssertNil(coalescer.note(sender: "b", at: 2))

    let later = coalescer.note(sender: "c", at: 31)

    XCTAssertTrue(later?.contains("c") == true)
    XCTAssertTrue(later?.contains("2 earlier") == true)
    XCTAssertNil(coalescer.note(sender: "c", at: 32))
  }
}
