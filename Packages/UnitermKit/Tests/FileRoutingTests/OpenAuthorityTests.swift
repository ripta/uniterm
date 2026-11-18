import FileRouting
import XCTest

final class OpenAuthorityTests: XCTestCase {
  private func sender(
    opener: String?, identifier: String? = "com.example.launcher", team: String? = "TEAM",
    apple: Bool = false
  ) -> SenderIdentity {
    SenderIdentity(
      pid: 9, pidVersion: 1, signingIdentifier: identifier, teamIdentifier: team,
      isPlatformBinary: apple, isAppleAnchored: apple, opener: opener)
  }

  /// Catches an authority that trusts a sender it should ask about, or asks about the user's own
  /// act. Apple's openers are the user's act. A third-party signed app may be allowed for its run.
  func testOnlyAnAppleOpenerIsTheUsersActAndAThirdPartyMayBeAllowedForItsRun() {
    let third = sender(opener: nil)

    XCTAssertEqual(
      OpenAuthority.decide(for: sender(opener: "Finder")), .userAct(opener: "Finder"))
    XCTAssertEqual(
      OpenAuthority.decide(for: third), .needsApproval(sender: third, onceOnly: false))
  }

  /// Catches a go-between that is offered a session grant. Every Apple-signed program that is not
  /// an opener gets Allow once only, whatever its identifier, since any program can drive it. So
  /// does a sender that could not be identified, and one with no signing identifier to name.
  func testGoBetweensAndUnidentifiedSendersGetAllowOnceOnly() {
    let open = sender(opener: nil, identifier: "com.apple.open", team: nil, apple: true)
    let unlisted = sender(
      opener: nil, identifier: "com.apple.never-measured", team: nil, apple: true)
    let unsigned = sender(opener: nil, identifier: nil, team: nil)

    XCTAssertEqual(OpenAuthority.decide(for: open), .needsApproval(sender: open, onceOnly: true))
    XCTAssertEqual(
      OpenAuthority.decide(for: unlisted), .needsApproval(sender: unlisted, onceOnly: true))
    XCTAssertEqual(
      OpenAuthority.decide(for: unsigned), .needsApproval(sender: unsigned, onceOnly: true))
    XCTAssertEqual(OpenAuthority.decide(for: nil), .needsApproval(sender: nil, onceOnly: true))
  }

  /// Catches a question that names a sender from anything but its verified signing information.
  func testTheApprovalLabelCarriesTheTeamOrSaysAppleOrNoTeam() {
    XCTAssertEqual(sender(opener: nil).approvalLabel, "com.example.launcher (team TEAM)")
    XCTAssertEqual(
      sender(opener: nil, identifier: "com.apple.open", team: nil, apple: true).approvalLabel,
      "com.apple.open (Apple)")
    XCTAssertEqual(
      sender(opener: nil, team: nil).approvalLabel, "com.example.launcher (no team)")
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

  /// Catches a refusal that does not say why nothing opened. Each reason reads differently, and
  /// each names the sender.
  func testEachRefusalNamesTheSenderAndSaysWhy() {
    let reasons: [(OpenAuthority.Refusal, String)] = [
      (.busy, "too many questions wait"), (.denied, "you denied it"),
      (.withdrawn, "quit before you answered"), (.noLocalFiles, "none of them is a local file"),
    ]

    for (reason, text) in reasons {
      let message = OpenAuthority.refusalMessage(sender: "com.example.x", reason: reason)

      XCTAssertTrue(message.contains("com.example.x"), "\(reason)")
      XCTAssertTrue(message.contains(text), "\(reason)")
    }
  }

  // MARK: Coalescing

  /// Catches a loop of refused opens that posts a message each time. A thousand refusals inside
  /// one interval post exactly one, naming the first sender.
  func testALoopOfRefusalsPostsOneMessagePerInterval() {
    var coalescer = RefusalCoalescer(interval: 30)
    var posted: [String] = []

    for index in 0..<1000 {
      if let text = coalescer.note(
        sender: "com.example.\(index)", reason: .busy, at: Double(index) * 0.01)
      {
        posted.append(text)
      }
    }

    XCTAssertEqual(posted.count, 1)
    XCTAssertTrue(posted[0].contains("com.example.0"))
  }

  /// Catches a coalescer that stays silent forever, or loses the count of what it folded.
  func testTheNextIntervalPostsAgainAndCountsTheFoldedOpens() {
    var coalescer = RefusalCoalescer(interval: 30)

    XCTAssertNotNil(coalescer.note(sender: "a", reason: .busy, at: 0))
    XCTAssertNil(coalescer.note(sender: "a", reason: .busy, at: 1))
    XCTAssertNil(coalescer.note(sender: "b", reason: .busy, at: 2))

    let later = coalescer.note(sender: "c", reason: .busy, at: 31)

    XCTAssertTrue(later?.contains("c") == true)
    XCTAssertTrue(later?.contains("2 earlier") == true)
    XCTAssertNil(coalescer.note(sender: "c", reason: .busy, at: 32))
  }
}
