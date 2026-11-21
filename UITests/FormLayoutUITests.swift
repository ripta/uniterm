import XCTest

/// Checks the layout of the Settings window in the running app, and attaches
/// a screenshot of each to the result bundle. Unit tests prove the frames in a bare window. These
/// prove them under the window server, in light and in dark.
@MainActor
final class FormLayoutUITests: UnitermUITestCase {
  private func attach(_ element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Catches Settings controls that start at different x positions, labels that end at different x
  /// positions, and a control that touches the window edge.
  func testSettingsFormIsAlignedAndInsideItsWindowInLightAndDark() {
    let app = launchApp()
    XCTAssertTrue(app.windows["main-window"].appears(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.appears(timeout: 5))

    let appearance = settings.radioGroups["appearance-control"]
    let statusBar = settings.radioGroups["status-bar-position-control"]
    let scriptFiles = settings.radioGroups["script-file-mode-control"]
    XCTAssertTrue(appearance.appears(timeout: 5))
    XCTAssertTrue(statusBar.exists)
    XCTAssertTrue(scriptFiles.exists, "Settings has no Script files row")
    XCTAssertTrue(scriptFiles.radioButtons["Strict"].exists)
    XCTAssertTrue(scriptFiles.radioButtons["Unsafe"].exists)
    XCTAssertEqual(
      scriptFiles.radioButtons["Strict"].value as? Int, 1, "Script files does not default to strict"
    )

    for (name, button) in [("light", "Light"), ("dark", "Dark")] {
      appearance.radioButtons[button].click()
      Thread.sleep(forTimeInterval: 0.5)

      let appearanceLabel = settings.staticTexts["Appearance:"]
      let statusLabel = settings.staticTexts["Status bar:"]
      let scriptFilesLabel = settings.staticTexts["Script files:"]
      XCTAssertEqual(appearance.frame.minX, statusBar.frame.minX, accuracy: 1, name)
      XCTAssertEqual(appearance.frame.minX, scriptFiles.frame.minX, accuracy: 1, name)
      XCTAssertEqual(appearanceLabel.frame.maxX, statusLabel.frame.maxX, accuracy: 4, name)
      XCTAssertEqual(appearanceLabel.frame.maxX, scriptFilesLabel.frame.maxX, accuracy: 4, name)

      for control in [appearance, statusBar, scriptFiles] {
        XCTAssertGreaterThanOrEqual(
          control.frame.minX, settings.frame.minX + 16, "\(name): too close to the leading edge")
        XCTAssertLessThanOrEqual(
          control.frame.maxX, settings.frame.maxX - 16, "\(name): too close to the trailing edge")
      }

      attach(settings, named: "settings-\(name)")
    }
  }
}
