import XCTest
import UIKit
import UniformTypeIdentifiers
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

    @MainActor
    func testSystemClipboardReaderPreservesOriginalImageBytes() throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        pasteboard.setData(data, forPasteboardType: UTType.png.identifier)

        let content = SystemClipboardSupport.read(from: pasteboard)

        XCTAssertEqual(
            content,
            .image(ImagePayload(data: data, typeIdentifier: UTType.png.identifier, filename: nil))
        )
    }

    @MainActor
    func testSystemClipboardReaderPreservesOriginalPDFBytes() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 120, height: 160)
        )
        let data = renderer.pdfData { context in
            context.beginPage()
            NSString(string: "Pocket Tray").draw(at: CGPoint(x: 12, y: 12))
        }
        pasteboard.setData(data, forPasteboardType: UTType.pdf.identifier)

        let content = SystemClipboardSupport.read(from: pasteboard)

        XCTAssertEqual(
            content,
            .pdf(PDFPayload(data: data, typeIdentifier: UTType.pdf.identifier, filename: nil))
        )
    }

    func testControlCaptureRequestIsConsumedExactlyOnce() {
        _ = ControlCaptureHandoff.consumeCaptureRequest()

        ControlCaptureHandoff.requestCapture()

        XCTAssertTrue(ControlCaptureHandoff.consumeCaptureRequest())
        XCTAssertFalse(ControlCaptureHandoff.consumeCaptureRequest())
    }
}
