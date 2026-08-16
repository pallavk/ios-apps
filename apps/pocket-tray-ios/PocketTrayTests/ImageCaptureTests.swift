import XCTest
@testable import PocketTray

final class ImageCaptureTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    func testImagePayloadProducesImmutableDigestMetadata() throws {
        let write = try ImageAssetFactory.makeWrite(
            from: ImagePayload(
                data: onePixelPNG,
                typeIdentifier: "public.png",
                filename: "shot.png"
            )
        )

        XCTAssertEqual(write.asset.byteCount, onePixelPNG.count)
        XCTAssertEqual(write.asset.typeIdentifier, "public.png")
        XCTAssertEqual(write.asset.fileExtension, "png")
        XCTAssertEqual(write.asset.originalFilename, "shot.png")
        XCTAssertEqual(write.data, onePixelPNG)
        XCTAssertEqual(write.asset.digest.count, 64)
    }

    func testImagePayloadRejectsMoreThanTwentyFiveMillionBytes() {
        let payload = ImagePayload(
            data: Data(repeating: 0, count: 25_000_001),
            typeIdentifier: "public.png",
            filename: nil
        )

        XCTAssertThrowsError(try ImageAssetFactory.makeWrite(from: payload)) {
            XCTAssertEqual(
                $0 as? TrayAssetError,
                .tooLarge(maximumBytes: ImageAssetFactory.maximumByteCount)
            )
        }
    }

    func testImagePayloadAcceptsExactlyTwentyFiveMillionBytes() throws {
        var paddedPNG = onePixelPNG
        paddedPNG.append(Data(repeating: 0, count: 25_000_000 - onePixelPNG.count))

        let write = try ImageAssetFactory.makeWrite(
            from: ImagePayload(
                data: paddedPNG,
                typeIdentifier: "public.png",
                filename: "limit.png"
            )
        )

        XCTAssertEqual(write.asset.byteCount, 25_000_000)
    }

    func testImagePayloadRejectsDeclaredImageWithInvalidBytes() {
        XCTAssertThrowsError(
            try ImageAssetFactory.makeWrite(
                from: ImagePayload(
                    data: Data("not an image".utf8),
                    typeIdentifier: "public.png",
                    filename: nil
                )
            )
        ) {
            XCTAssertEqual($0 as? TrayAssetError, .invalidImage)
        }
    }

    func testIdenticalImagesDeduplicateAndPreserveMetadata() async throws {
        let repository = InMemoryTrayRepository()
        let firstTray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let original = try await firstTray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "first.png"
                )
            )
        )
        let collection = try await firstTray.createCollection(named: "Screenshots")
        _ = try await firstTray.edit(
            original.id,
            text: original.text,
            title: "Keep title",
            note: "Keep note",
            collectionID: collection.id
        )
        _ = try await firstTray.setPinned(original.id, to: true)

        let secondTray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let recaptured = try await secondTray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "second.png"
                )
            )
        )
        let recent = try await secondTray.recent()

        XCTAssertEqual(recaptured.id, original.id)
        XCTAssertEqual(recaptured.kind, .image)
        XCTAssertEqual(recaptured.asset?.digest, original.asset?.digest)
        XCTAssertEqual(recaptured.title, "Keep title")
        XCTAssertEqual(recaptured.note, "Keep note")
        XCTAssertEqual(recaptured.collectionID, collection.id)
        XCTAssertTrue(recaptured.isPinned)
        XCTAssertEqual(recent.count, 1)
    }
}
