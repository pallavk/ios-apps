import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImageShareCaptureTests: XCTestCase {
    private struct ImageShareProvider: ShareItemProviding {
        let payload: ImagePayload
        let failsToLoad: Bool

        var canLoadImage: Bool { true }
        var canLoadURL: Bool { true }
        var canLoadText: Bool { true }

        func loadImage() async throws -> ImagePayload {
            if failsToLoad {
                throw CocoaError(.fileReadCorruptFile)
            }
            return payload
        }

        func loadURL() async throws -> URL {
            URL(string: "https://wrong.example")!
        }

        func loadText() async throws -> String {
            "wrong"
        }
    }

    private struct CancellationIgnoringImageProvider: ShareItemProviding {
        let payload: ImagePayload

        var canLoadImage: Bool { true }
        var canLoadURL: Bool { false }
        var canLoadText: Bool { false }

        func loadImage() async throws -> ImagePayload {
            try? await Task.sleep(for: .milliseconds(50))
            return payload
        }

        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { throw ShareCaptureError.unsupported }
    }

    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    func testShareCapturePrefersImageRepresentation() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let item = try await ShareCapture(tray: tray).capture(
            ImageShareProvider(
                payload: ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "shot.png"
                ),
                failsToLoad: false
            )
        )
        let resource = try await tray.assetResource(for: item)

        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.asset?.typeIdentifier, "public.png")
        XCTAssertEqual(resource.data, onePixelPNG)
    }

    func testUnreadableSharedImageCreatesNoObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = ImageShareProvider(
            payload: ImagePayload(
                data: onePixelPNG,
                typeIdentifier: "public.png",
                filename: "shot.png"
            ),
            failsToLoad: true
        )

        do {
            _ = try await ShareCapture(tray: tray).capture(provider)
            XCTFail("Expected an unreadable share error")
        } catch {
            XCTAssertEqual(error as? ShareCaptureError, .unreadable)
        }
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testCancellingSharedImageCaptureCreatesNoObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = CancellationIgnoringImageProvider(
            payload: ImagePayload(
                data: onePixelPNG,
                typeIdentifier: "public.png",
                filename: "cancelled.png"
            )
        )
        let captureTask = Task {
            try await ShareCapture(tray: tray).capture(provider)
        }
        try await Task.sleep(for: .milliseconds(10))
        captureTask.cancel()

        do {
            _ = try await captureTask.value
            XCTFail("Expected capture cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testShareCapturePreservesJPEGRepresentationBytes() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let tray = Tray(repository: InMemoryTrayRepository())

        let item = try await ShareCapture(tray: tray).capture(
            ImageShareProvider(
                payload: ImagePayload(
                    data: jpeg,
                    typeIdentifier: "public.jpeg",
                    filename: "photo.jpg"
                ),
                failsToLoad: false
            )
        )
        let resource = try await tray.assetResource(for: item)

        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.asset?.fileExtension, "jpeg")
        XCTAssertEqual(resource.data, jpeg)
        XCTAssertEqual(resource.exportURL.lastPathComponent, "photo.jpg")
    }
}
