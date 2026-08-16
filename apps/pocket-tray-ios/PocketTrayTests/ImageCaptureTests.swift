import XCTest
@testable import PocketTray

final class ImageCaptureTests: XCTestCase {
    private struct RejectingAssetWriter: AssetDataWriting {
        func write(_ data: Data, to finalURL: URL) throws {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private struct InterruptedAssetWriter: AssetDataWriting {
        func write(_ data: Data, to finalURL: URL) throws {
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(
                to: finalURL.deletingLastPathComponent().appending(path: ".interrupted.tmp")
            )
            throw CocoaError(.fileWriteUnknown)
        }
    }

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

    func testOriginalImageBytesSurviveRepositoryRelaunch() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "tray.json")
        let first = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let item = try await first.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "original.png"
                )
            )
        )

        let second = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let resource = try await second.assetResource(for: item)
        let recent = try await second.recent()

        XCTAssertEqual(resource.data, onePixelPNG)
        XCTAssertEqual(try Data(contentsOf: resource.url), onePixelPNG)
        XCTAssertEqual(recent.first?.id, item.id)
    }

    func testMissingAndCorruptAssetsRemainRecordsButCannotBeRead() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )
        let item = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: "shot.png"
                )
            )
        )
        let asset = try XCTUnwrap(item.asset)
        let assetURL = root.appending(
            path: "assets/\(asset.digest).\(asset.fileExtension)"
        )

        try FileManager.default.removeItem(at: assetURL)
        do {
            _ = try await tray.assetResource(for: item)
            XCTFail("Expected a missing-asset error")
        } catch {
            XCTAssertEqual(error as? TrayAssetError, .missing)
        }
        let recentAfterMissingAsset = try await tray.recent()
        XCTAssertEqual(recentAfterMissingAsset.map(\.id), [item.id])

        try onePixelPNG.write(to: assetURL)
        try Data(onePixelPNG.prefix(8)).write(to: assetURL)
        do {
            _ = try await tray.assetResource(for: item)
            XCTFail("Expected a corrupt-asset error")
        } catch {
            XCTAssertEqual(error as? TrayAssetError, .corrupt)
        }
        let recentAfterCorruptAsset = try await tray.recent()
        XCTAssertEqual(recentAfterCorruptAsset.map(\.id), [item.id])
    }

    func testAssetWriteFailuresCreateNoRecordOrFinalAsset() async throws {
        for writer in [
            AnyAssetDataWriter(RejectingAssetWriter()),
            AnyAssetDataWriter(InterruptedAssetWriter())
        ] {
            let root = try temporaryRoot()
            let tray = Tray(
                repository: FileTrayRepository(
                    fileURL: root.appending(path: "tray.json"),
                    assetWriter: writer
                )
            )

            do {
                _ = try await tray.capture(
                    .image(
                        ImagePayload(
                            data: onePixelPNG,
                            typeIdentifier: "public.png",
                            filename: "failed.png"
                        )
                    )
                )
                XCTFail("Expected the asset write to fail")
            } catch {
                XCTAssertTrue(error is CocoaError)
            }

            let recent = try await tray.recent()
            XCTAssertTrue(recent.isEmpty)
            let finalAssets = try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "assets"),
                includingPropertiesForKeys: nil
            ).filter { !$0.lastPathComponent.hasPrefix(".") }
            XCTAssertTrue(finalAssets.isEmpty)
        }
    }

    func testOverLimitImageCreatesNoRecordOrAsset() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )

        do {
            _ = try await tray.capture(
                .image(
                    ImagePayload(
                        data: Data(repeating: 0, count: 25_000_001),
                        typeIdentifier: "public.png",
                        filename: "too-large.png"
                    )
                )
            )
            XCTFail("Expected the size limit to reject the image")
        } catch {
            XCTAssertEqual(
                error as? TrayAssetError,
                .tooLarge(maximumBytes: ImageAssetFactory.maximumByteCount)
            )
        }

        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
        let assetsURL = root.appending(path: "assets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetsURL.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
