import XCTest

@MainActor
final class PocketTrayShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrimaryDestinationsPreserveRecentFilterState() {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["Recent"].exists)
        XCTAssertTrue(app.tabBars.buttons["Collections"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.tabBars.buttons["Pinned"].exists)
        XCTAssertFalse(app.tabBars.buttons["Trash"].exists)

        let pinned = app.segmentedControls.buttons["Pinned"]
        pinned.tap()
        XCTAssertTrue(pinned.isSelected)

        app.tabBars.buttons["Collections"].tap()
        app.tabBars.buttons["Recent"].tap()
        XCTAssertTrue(pinned.isSelected)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Trash"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields["Search Pocket Tray"].waitForExistence(timeout: 3))
    }

    func testClipboardCaptureActionReturnsToAddAfterSaving() {
        let app = launchApp(clipboardAvailable: true)
        let primaryAction = app.buttons["primary-capture-action"]

        XCTAssertTrue(primaryAction.waitForExistence(timeout: 3))
        XCTAssertEqual(primaryAction.label, "Save Clipboard")
        primaryAction.tap()

        XCTAssertTrue(app.staticTexts["Saved to Pocket Tray"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["primary-capture-action"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["primary-capture-action"].label, "Add")
    }

    private func launchApp(clipboardAvailable: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if clipboardAvailable {
            app.launchArguments.append("--ui-testing-clipboard")
        }
        app.launch()
        return app
    }
}
