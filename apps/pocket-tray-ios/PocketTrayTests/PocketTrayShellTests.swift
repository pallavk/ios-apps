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
}
