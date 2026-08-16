import XCTest
@testable import PocketTray

final class DirectCaptureTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    func testCancellingDirectCaptureCreatesNoObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let service = DirectCaptureService(tray: tray)

        let saved = try await service.capture(nil)

        XCTAssertNil(saved)
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testDirectTextCaptureUsesTheTrayCapturePath() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let service = DirectCaptureService(tray: tray)

        let saved = try await service.capture(.text("  A quick note  "))

        XCTAssertEqual(saved?.kind, .text)
        XCTAssertEqual(saved?.text, "  A quick note  ")
        let recent = try await tray.recent()
        XCTAssertEqual(recent.map(\.id), [saved?.id].compactMap { $0 })
    }

    func testDirectCaptureCommitsOptionalDetailsWithTheObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let collection = try await tray.createCollection(named: "Ideas")
        let service = DirectCaptureService(tray: tray)

        let saved = try await service.capture(
            .text("Feature thought"),
            details: DirectCaptureDetails(
                title: "Pocket Tray",
                note: "Review tomorrow",
                collectionID: collection.id
            )
        )

        XCTAssertEqual(saved?.title, "Pocket Tray")
        XCTAssertEqual(saved?.note, "Review tomorrow")
        XCTAssertEqual(saved?.collectionID, collection.id)
    }

    func testDirectImageCapturePreservesOriginalByteIdentity() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let service = DirectCaptureService(tray: tray)

        let saved = try await service.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "photo.png"
                )
            )
        )

        XCTAssertEqual(saved?.kind, .image)
        XCTAssertEqual(saved?.asset?.byteCount, onePixelPNG.count)
        XCTAssertEqual(saved?.asset?.digest, ImageAssetFactory.digest(of: onePixelPNG))
        XCTAssertEqual(saved?.asset?.originalFilename, "photo.png")
    }
}
