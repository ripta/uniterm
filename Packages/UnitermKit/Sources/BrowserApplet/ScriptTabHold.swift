import Foundation

/// What a page's script has tried to open past the pane's limit on script-opened tabs, and what
/// the user said about it.
///
/// WebKit asks for a new window synchronously, so the call cannot wait for the user. The call is
/// refused and its address is remembered here. The pane then asks whether the page may open more,
/// and a yes opens the remembered addresses.
struct ScriptTabHold {
  enum Phase: Equatable {
    /// The page has not passed the limit since its last load.
    case counting

    /// The page passed the limit and no question was asked yet, since another one was up.
    case waiting

    /// The question about this page is up.
    case asking

    /// The user let the page open tabs until its next load.
    case granted

    /// The user refused, so every further call from the page is refused until its next load.
    case refused
  }

  /// The most addresses one page's refused calls keep. Past this, addresses are only counted. A
  /// policy value with no setting.
  static let addressLimit = 50

  private(set) var phase = Phase.counting
  private(set) var addresses: [URL] = []

  /// How many refused calls were not kept, because the list was full or the call named no address.
  private(set) var dropped = 0

  /// Changes at every load, so an answer to a question about an earlier load is told apart.
  private(set) var epoch = 0

  /// Every refused call since the last load, kept or not.
  var attempts: Int { addresses.count + dropped }

  /// Remembers a refused call. A call with no address cannot be opened later, so it is only
  /// counted.
  mutating func remember(_ url: URL?) {
    guard let url, !url.absoluteString.isEmpty, addresses.count < Self.addressLimit else {
      dropped += 1
      return
    }

    addresses.append(url)
  }

  mutating func setPhase(_ phase: Phase) {
    self.phase = phase
  }

  /// Hands over the remembered addresses and forgets them.
  @discardableResult
  mutating func takeAddresses() -> [URL] {
    let taken = addresses

    addresses = []
    dropped = 0

    return taken
  }

  /// The page loaded again. Everything from the earlier load ends.
  mutating func reset() {
    self = ScriptTabHold(epoch: epoch &+ 1)
  }

  private init(epoch: Int) {
    self.epoch = epoch
  }

  init() {}
}
