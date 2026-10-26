import XCTest

/// End-to-end: launches the real app and drives it through the accessibility tree.
/// Locally, the Forewarn icon must be visible: menu bar managers that hide new items make the click miss.
final class MenuBarUITests: XCTestCase {
    @MainActor
    func testPopoverOpensFromMenuBarAndLeadsToSettings() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        XCTAssertTrue(app.staticTexts["Still learning your habits"].waitForExistence(timeout: 5))

        app.buttons["Settings…"].click()
        // Assert presence only: toggling would register a real login item.
        XCTAssertTrue(app.switches["Launch at login"].waitForExistence(timeout: 5))
    }
}
