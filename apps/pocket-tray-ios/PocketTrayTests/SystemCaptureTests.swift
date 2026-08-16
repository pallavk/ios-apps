import XCTest
@testable import PocketTray

final class SystemCaptureTests: XCTestCase {
    private struct Reader: ClipboardContentReading {
        let content: CaptureContent
        func readCurrentContent() async -> CaptureContent { content }
    }

    func testShortcutCaptureUsesTrayURLNormalizationAndDeduplication() async throws {
        let repository = InMemoryTrayRepository()
        let tray = Tray(repository: repository)
        let service = ClipboardCaptureService(
            tray: tray,
            reader: Reader(content: .text("https://example.com/path"))
        )

        let first = await service.captureCurrentContent()
        let second = await service.captureCurrentContent()

        guard case let .saved(firstItem) = first else {
            return XCTFail("Expected the shortcut capture to save")
        }
        guard case let .saved(secondItem) = second else {
            return XCTFail("Expected recapture to save")
        }
        XCTAssertEqual(firstItem.kind, .url)
        XCTAssertEqual(firstItem.id, secondItem.id)
        let recent = try await tray.recent()
        XCTAssertEqual(recent.count, 1)
    }

    func testShortcutCaptureDoesNotStoreSensitiveTextWithoutReview() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let service = ClipboardCaptureService(
            tray: tray,
            reader: Reader(content: .text("Verification code: 739201"))
        )

        let outcome = await service.captureCurrentContent()

        XCTAssertEqual(outcome, .requiresSensitiveReview([.oneTimeCode]))
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testShortcutCaptureReportsUnsupportedClipboardContent() async {
        let service = ClipboardCaptureService(
            tray: Tray(repository: InMemoryTrayRepository()),
            reader: Reader(content: .unsupported)
        )

        let outcome = await service.captureCurrentContent()
        XCTAssertEqual(outcome, .unsupported)
    }
}
