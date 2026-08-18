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

    func testSavedObjectOpensContentFirstDetail() {
        let app = launchApp(withContent: true)

        let object = app.staticTexts["Ideas for the weekend"]
        XCTAssertTrue(object.waitForExistence(timeout: 3))
        object.tap()

        let primaryAction = app.buttons["detail-primary-action"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 3))
        XCTAssertEqual(primaryAction.label, "Copy Text")
        app.buttons["Done"].tap()

        app.staticTexts["SwiftUI design guidance"].tap()
        XCTAssertTrue(app.buttons["detail-primary-action"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["detail-primary-action"].label, "Open Link")
    }

    func testQuickCopyIsOffByDefaultInSettings() {
        let app = launchApp()

        app.buttons["Settings"].tap()
        let toggle = app.switches["Quick Copy on Tap"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testPinActionOffersUndo() {
        let app = launchApp(withContent: true)

        app.buttons["Object options"].firstMatch.tap()
        app.buttons["Pin"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(app.staticTexts["Undone"].waitForExistence(timeout: 3))
    }

    func testMediaObjectsOpenPurposeBuiltDetailsAndErrorsStayVisible() {
        let app = launchApp(withContent: true)

        let image = app.staticTexts["Bintan coastline"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        image.tap()
        XCTAssertTrue(app.buttons["detail-primary-action"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["detail-primary-action"].label, "Share Original")
        app.buttons["Done"].tap()

        let pdf = app.staticTexts["Trip notes"]
        if !pdf.exists { app.swipeUp() }
        XCTAssertTrue(pdf.waitForExistence(timeout: 3))
        pdf.tap()
        XCTAssertTrue(app.buttons["detail-primary-action"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["detail-primary-action"].label, "Share Original")
        app.buttons["Done"].tap()

        let missing = app.staticTexts["Missing receipt"]
        for _ in 0..<3 where !missing.exists { app.swipeUp() }
        XCTAssertTrue(missing.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Original unavailable"].waitForExistence(timeout: 3))
    }

    func testSensitiveFixtureStaysCoveredUntilExplicitlyRevealed() {
        let app = launchApp(withContent: true)
        let cover = app.descendants(matching: .any)["sensitive-content-cover"].firstMatch

        for _ in 0..<6 where !cover.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(cover.exists)
        XCTAssertFalse(app.staticTexts["Verification code: 739201"].exists)
    }

    func testAccessibilityDynamicTypeKeepsContentAndPrimaryActionReachable() {
        let app = launchApp(withContent: true, accessibilitySize: true)

        let object = app.staticTexts["Ideas for the weekend"]
        XCTAssertTrue(object.waitForExistence(timeout: 3))
        object.tap()
        XCTAssertTrue(app.buttons["detail-primary-action"].waitForExistence(timeout: 3))
    }

    func testCollectionsUseContentLedCardsAndUsefulEmptyState() {
        let app = launchApp(withContent: true)

        app.tabBars.buttons["Collections"].tap()
        XCTAssertTrue(app.buttons["Projects, 1 object"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Travel, 3 objects"].exists)
        XCTAssertTrue(app.buttons["Inbox, 0 objects"].exists)
        XCTAssertTrue(app.buttons["Options for Projects"].exists)

        app.buttons["Inbox, 0 objects"].tap()
        XCTAssertTrue(app.staticTexts["Collection is empty"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Existing Objects"].exists)
        XCTAssertTrue(app.buttons["Add New Text"].exists)
    }

    func testDeletingCollectionKeepsObjectsAndOffersUndo() {
        let app = launchApp(withContent: true)

        app.tabBars.buttons["Collections"].tap()
        app.buttons["Options for Projects"].tap()
        app.buttons["Delete Collection"].tap()
        XCTAssertTrue(app.staticTexts["Collection deleted. Objects kept."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Undo"].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons["Projects, 1 object"].waitForExistence(timeout: 3))
    }

    func testRepeatedCollectionMovesUndoToTheImmediatelyPreviousState() {
        let app = launchApp(withContent: true)

        app.tabBars.buttons["Collections"].tap()
        app.buttons["Travel, 3 objects"].tap()
        app.buttons["Add Existing Objects"].tap()

        let object = app.buttons["Pickleball court setup"]
        XCTAssertTrue(object.waitForExistence(timeout: 3))
        XCTAssertEqual(object.value as? String, "Not in collection")
        object.tap()
        XCTAssertEqual(object.value as? String, "In collection")
        object.tap()
        XCTAssertEqual(object.value as? String, "Not in collection")

        app.buttons["Undo"].tap()
        XCTAssertEqual(object.value as? String, "In collection")
    }

    func testSearchHomeIsUsefulBeforeTypingAndCombinesFilters() {
        let app = launchApp(withContent: true)

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recently Saved"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Collections"].exists)
        XCTAssertFalse(app.staticTexts["Verification code: 739201"].exists)

        let search = app.searchFields["Search Pocket Tray"]
        search.tap()
        search.typeText("Trip")
        XCTAssertTrue(app.staticTexts["Trip notes"].waitForExistence(timeout: 3))

        app.buttons["All"].tap()
        app.buttons["PDFs"].tap()
        app.buttons["Any Collection"].tap()
        app.buttons["Travel"].tap()
        XCTAssertTrue(app.staticTexts["Trip notes"].exists)
        XCTAssertFalse(app.staticTexts["Ideas for the weekend"].exists)
    }

    func testSearchHomeRemainsReachableAtAccessibilityDynamicType() {
        let app = launchApp(withContent: true, accessibilitySize: true)

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Recently Saved"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Any Collection"].exists)
    }

    private func launchApp(
        clipboardAvailable: Bool = false,
        withContent: Bool = false,
        accessibilitySize: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if clipboardAvailable {
            app.launchArguments.append("--ui-testing-clipboard")
        }
        if withContent {
            app.launchArguments.append("--ui-testing-content")
        }
        if accessibilitySize {
            app.launchArguments.append("--ui-testing-accessibility-size")
        }
        app.launch()
        return app
    }
}
