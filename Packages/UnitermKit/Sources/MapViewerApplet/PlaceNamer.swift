import GeoData
import PlaceSearch

/// Names the place at the center of the map, for the palette.
///
/// A name costs a request to Apple, so a move that cannot change the name asks nothing. A move
/// within a quarter of the view at the same scale keeps the last answer. A newer request replaces
/// an older one, and the older answer is dropped.
///
/// The name is never saved. A pane that is restored asks again, and a failed lookup, such as one
/// made offline, leaves no name.
@MainActor
final class PlaceNamer {
  /// Gets each new name, or nil when there is none.
  var onName: ((String?) -> Void)?

  private let lookup: PlaceLookup?

  private(set) var name: String?
  private(set) var pending: Task<Void, Never>?
  private var asked: (center: GeoCoordinate, span: GeoSpan, scale: PlaceScale)?

  init(lookup: PlaceLookup?) {
    self.lookup = lookup
  }

  /// Looks up the name for `region`, unless the last lookup already covers it.
  func regionShown(_ region: GeoRegion) {
    guard let lookup else { return }

    let scale = PlaceScale(region.span)

    if let asked, asked.scale == scale,
      abs(asked.center.latitude - region.center.latitude) < asked.span.latitudeDelta / 4,
      abs(asked.center.longitude - region.center.longitude) < asked.span.longitudeDelta / 4
    {
      return
    }

    asked = (region.center, region.span, scale)
    pending?.cancel()

    pending = Task { [weak self] in
      let found = await lookup(region.center, scale)

      guard !Task.isCancelled, let self else { return }

      self.pending = nil
      self.publish(found)
    }
  }

  /// Drops any lookup in flight. The owner calls it when the pane closes.
  func cancel() {
    pending?.cancel()
    pending = nil
    onName = nil
  }

  private func publish(_ found: String?) {
    let trimmed = found?.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = trimmed?.isEmpty == false ? trimmed : nil

    guard next != name else { return }

    name = next
    onName?(next)
  }
}
