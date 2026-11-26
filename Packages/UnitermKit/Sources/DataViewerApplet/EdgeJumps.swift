import AppKit
import Theme

/// Small arrow buttons on the table's four edges that scroll to the first or last column or row.
///
/// A pair shows only when its axis is long: the columns pass `threshold` times the columns in view,
/// or the rows pass it times the rows in view. A table that fits a few screens scrolls well enough
/// by hand, and the arrows would only cover cells.
@MainActor
final class EdgeJumps: NSObject {
  enum Edge: CaseIterable {
    case firstColumn
    case lastColumn
    case firstRow
    case lastRow

    var symbol: String {
      switch self {
      case .firstColumn: return "arrow.left.to.line"
      case .lastColumn: return "arrow.right.to.line"
      case .firstRow: return "arrow.up.to.line"
      case .lastRow: return "arrow.down.to.line"
      }
    }

    var label: String {
      switch self {
      case .firstColumn: return "Scroll to the first column"
      case .lastColumn: return "Scroll to the last column"
      case .firstRow: return "Scroll to the first row"
      case .lastRow: return "Scroll to the last row"
      }
    }

    var identifier: String {
      switch self {
      case .firstColumn: return "data-viewer-jump-first-column"
      case .lastColumn: return "data-viewer-jump-last-column"
      case .firstRow: return "data-viewer-jump-first-row"
      case .lastRow: return "data-viewer-jump-last-row"
      }
    }
  }

  static let threshold = 10
  private static let size: CGFloat = 24

  /// Room left for a scroller that takes space, so an arrow never sits on it.
  private static let scrollerRoom: CGFloat = 18

  /// Room for the table's header row above the first row.
  private static let headerRoom: CGFloat = 30

  private(set) var buttons: [Edge: NSButton] = [:]
  var onJump: ((Edge) -> Void)?

  func install(in parent: NSView, over scrollView: NSScrollView, suffix: String) {
    for edge in Edge.allCases {
      let button = NSButton(
        image: NSImage(systemSymbolName: edge.symbol, accessibilityDescription: edge.label)
          ?? NSImage(),
        target: self, action: #selector(pressed(_:)))

      button.isBordered = false
      button.imageScaling = .scaleProportionallyDown
      button.wantsLayer = true
      button.layer?.cornerRadius = Self.size / 2
      button.toolTip = edge.label
      button.setAccessibilityLabel(edge.label)
      button.setAccessibilityIdentifier(edge.identifier + suffix)
      button.isHidden = true
      button.translatesAutoresizingMaskIntoConstraints = false
      parent.addSubview(button, positioned: .above, relativeTo: scrollView)
      buttons[edge] = button

      var constraints = [
        button.widthAnchor.constraint(equalToConstant: Self.size),
        button.heightAnchor.constraint(equalToConstant: Self.size),
      ]

      switch edge {
      case .firstColumn:
        constraints += [
          button.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 6),
          button.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ]

      case .lastColumn:
        constraints += [
          button.trailingAnchor.constraint(
            equalTo: scrollView.trailingAnchor, constant: -Self.scrollerRoom),
          button.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ]

      case .firstRow:
        constraints += [
          button.topAnchor.constraint(
            equalTo: scrollView.topAnchor, constant: Self.headerRoom),
          button.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
        ]

      case .lastRow:
        constraints += [
          button.bottomAnchor.constraint(
            equalTo: scrollView.bottomAnchor, constant: -Self.scrollerRoom),
          button.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
        ]
      }

      NSLayoutConstraint.activate(constraints)
    }
  }

  func apply(_ palette: ThemePalette) {
    for button in buttons.values {
      button.layer?.backgroundColor = palette[.surface0].nsColor.withAlphaComponent(0.9).cgColor
      button.contentTintColor = palette[.text].nsColor
    }
  }

  /// Shows each pair when its axis is long enough, and hides both when the table does not show.
  func update(
    showsTable: Bool, columns: Int, visibleColumns: Int, rows: Int, visibleRows: Int
  ) {
    let wide = showsTable && visibleColumns > 0 && columns > Self.threshold * visibleColumns
    let tall = showsTable && visibleRows > 0 && rows > Self.threshold * visibleRows

    buttons[.firstColumn]?.isHidden = !wide
    buttons[.lastColumn]?.isHidden = !wide
    buttons[.firstRow]?.isHidden = !tall
    buttons[.lastRow]?.isHidden = !tall
  }

  @objc private func pressed(_ sender: NSButton) {
    guard let edge = buttons.first(where: { $0.value === sender })?.key else { return }

    onJump?(edge)
  }
}
