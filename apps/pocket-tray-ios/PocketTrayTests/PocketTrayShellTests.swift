import XCTest
@testable import PocketTray

final class PocketTrayShellTests: XCTestCase {
    func testPrimaryNavigationContainsOnlyRecentCollectionsAndSearch() {
        XCTAssertEqual(PocketTraySection.allCases, [.recent, .collections, .search])
    }

    func testRecentFilterKeepsPinnedObjectsInsideRecent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let unpinned = TrayItem(id: UUID(), text: "Unpinned", capturedAt: now)
        let pinned = TrayItem(id: UUID(), text: "Pinned", capturedAt: now, isPinned: true)

        XCTAssertEqual(
            RecentFilter.all.items(from: [unpinned, pinned]).map(\.id),
            [unpinned.id, pinned.id]
        )
        XCTAssertEqual(
            RecentFilter.pinned.items(from: [unpinned, pinned]).map(\.id),
            [pinned.id]
        )
    }

    func testBottomCaptureActionBecomesSaveClipboardOnlyWhilePromptIsVisible() {
        XCTAssertEqual(CaptureActionMode(clipboardPromptIsVisible: false), .add)
        XCTAssertEqual(CaptureActionMode(clipboardPromptIsVisible: true), .saveClipboard)
    }

    func testRecentObjectsGroupIntoTodayYesterdayAndEarlier() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 15))
        )
        let today = TrayItem(id: UUID(), text: "Today", capturedAt: now.addingTimeInterval(-60))
        let yesterday = TrayItem(
            id: UUID(),
            text: "Yesterday",
            capturedAt: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        )
        let earlier = TrayItem(
            id: UUID(),
            text: "Earlier",
            capturedAt: try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: now))
        )

        let sections = TrayItemSection.group(
            [today, yesterday, earlier],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(sections.map(\.period), [.today, .yesterday, .earlier])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[today.id], [yesterday.id], [earlier.id]])
    }

    func testQuickCopyIsOptInAndNeverAppliesToSensitiveOrMediaObjects() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let text = TrayItem(id: UUID(), text: "Reusable", capturedAt: now)
        let link = TrayItem(id: UUID(), kind: .url, text: "https://example.com", capturedAt: now)
        let image = TrayItem(id: UUID(), kind: .image, text: "Image", capturedAt: now)
        let sensitive = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: now,
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode])
        )

        XCTAssertFalse(QuickCopyPolicy.shouldCopyOnTap(text, isEnabled: false))
        XCTAssertTrue(QuickCopyPolicy.shouldCopyOnTap(text, isEnabled: true))
        XCTAssertTrue(QuickCopyPolicy.shouldCopyOnTap(link, isEnabled: true))
        XCTAssertFalse(QuickCopyPolicy.shouldCopyOnTap(image, isEnabled: true))
        XCTAssertFalse(QuickCopyPolicy.shouldCopyOnTap(sensitive, isEnabled: true))
    }

}
