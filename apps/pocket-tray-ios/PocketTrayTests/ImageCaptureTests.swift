import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImageCaptureTests: XCTestCase {
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

    private struct RejectingMetadataWriter: TrayMetadataWriting {
        func write(_ data: Data, to url: URL) throws {
            throw CocoaError(.fileWriteOutOfSpace)
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

    func testImagePayloadRejectsContainerWithoutDecodableFrame() {
        let truncatedContainer = Data(onePixelPNG.prefix(40))

        XCTAssertThrowsError(
            try ImageAssetFactory.makeWrite(
                from: ImagePayload(
                    data: truncatedContainer,
                    typeIdentifier: "public.png",
                    filename: "truncated.png"
                )
            )
        ) {
            XCTAssertEqual($0 as? TrayAssetError, .invalidImage)
        }
    }

    func testImagePayloadDerivesConcreteTypeFromBytes() throws {
        let write = try ImageAssetFactory.makeWrite(
            from: ImagePayload(
                data: onePixelPNG,
                typeIdentifier: "public.image",
                filename: "abstract"
            )
        )

        XCTAssertEqual(write.asset.typeIdentifier, "public.png")
        XCTAssertEqual(write.asset.fileExtension, "png")
    }

    func testNonImageTypeCreatesNoRecordOrAsset() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )

        do {
            _ = try await tray.capture(
                .image(
                    ImagePayload(
                        data: Data("not an image".utf8),
                        typeIdentifier: UTType.plainText.identifier,
                        filename: "notes.txt"
                    )
                )
            )
            XCTFail("Expected a non-image type to be rejected")
        } catch {
            XCTAssertEqual(error as? TrayAssetError, .unsupportedType)
        }

        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "assets").path)
        )
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
        XCTAssertEqual(resource.exportURL.lastPathComponent, "original.png")
        XCTAssertEqual(try Data(contentsOf: resource.exportURL), onePixelPNG)
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

    func testSameSizeDigestMismatchRemainsARecordButCannotBeRead() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )
        let item = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.png.identifier,
                    filename: "shot.png"
                )
            )
        )
        let asset = try XCTUnwrap(item.asset)
        let assetURL = root.appending(
            path: "assets/\(asset.digest).\(asset.fileExtension)"
        )
        var changedBytes = onePixelPNG
        changedBytes[changedBytes.startIndex] ^= 0x01
        try changedBytes.write(to: assetURL)

        do {
            _ = try await tray.assetResource(for: item)
            XCTFail("Expected a digest mismatch error")
        } catch {
            XCTAssertEqual(error as? TrayAssetError, .corrupt)
        }
        let recent = try await tray.recent()
        XCTAssertEqual(recent.map(\.id), [item.id])
    }

    func testInternallyConsistentUndecodableAssetRemainsARecordButCannotBeRead() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "tray.json")
        let undecodableData = Data(onePixelPNG.prefix(40))
        let asset = TrayAsset(
            digest: ImageAssetFactory.digest(of: undecodableData),
            byteCount: undecodableData.count,
            typeIdentifier: UTType.png.identifier,
            fileExtension: "png",
            originalFilename: "broken.png"
        )
        let now = Date()
        let item = TrayItem(
            id: UUID(),
            kind: .image,
            text: "broken.png",
            capturedAt: now,
            asset: asset,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        try FileManager.default.createDirectory(
            at: root.appending(path: "assets"),
            withIntermediateDirectories: true
        )
        try undecodableData.write(
            to: root.appending(path: "assets/\(asset.digest).png")
        )
        try JSONEncoder().encode(TrayStore(items: [item])).write(to: fileURL)

        let relaunched = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recent = try await relaunched.recent()
        XCTAssertEqual(recent.map(\.id), [item.id])
        do {
            _ = try await relaunched.assetResource(for: item)
            XCTFail("Expected an undecodable asset error")
        } catch {
            XCTAssertEqual(error as? TrayAssetError, .corrupt)
        }
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
                XCTAssertTrue(error is TrayPersistenceError)
                XCTAssertTrue(error.localizedDescription.contains("Pocket Tray"))
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

    func testMetadataFailureRollsBackNewAssetAndReportsNoSuccessfulCapture() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(
                fileURL: root.appending(path: "tray.json"),
                metadataWriter: RejectingMetadataWriter()
            )
        )

        do {
            _ = try await tray.capture(
                .image(
                    ImagePayload(
                        data: onePixelPNG,
                        typeIdentifier: UTType.png.identifier,
                        filename: "not-saved.png"
                    )
                )
            )
            XCTFail("Expected metadata storage to fail")
        } catch {
            XCTAssertEqual(error as? TrayPersistenceError, .insufficientStorage)
        }

        let assetsURL = root.appending(path: "assets")
        let visibleAssets = (try? FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        ))?.filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        XCTAssertTrue(visibleAssets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "tray.json").path))
    }

    func testStorageReportCountsUniqueOriginalBytesAndUnavailableAssets() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )
        let first = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.png.identifier,
                    filename: "first.png"
                )
            )
        )
        _ = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.png.identifier,
                    filename: "same-bytes.png"
                )
            )
        )

        let healthy = try await tray.storageReport()
        XCTAssertEqual(healthy.assetBytes, Int64(onePixelPNG.count))
        XCTAssertEqual(healthy.unavailableAssetCount, 0)

        let asset = try XCTUnwrap(first.asset)
        try FileManager.default.removeItem(
            at: root.appending(path: "assets/\(asset.digest).\(asset.fileExtension)")
        )
        let missing = try await tray.storageReport()
        XCTAssertEqual(missing.assetBytes, 0)
        XCTAssertEqual(missing.unavailableAssetCount, 1)
    }

    func testPermanentDeletionReclaimsTheOriginalAsset() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )
        let item = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.png.identifier,
                    filename: "delete-me.png"
                )
            )
        )
        let asset = try XCTUnwrap(item.asset)
        let assetURL = root.appending(path: "assets/\(asset.digest).\(asset.fileExtension)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))

        _ = try await tray.moveToTrash(item.id)
        try await tray.deletePermanently(item.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
        let report = try await tray.storageReport()
        XCTAssertEqual(report.assetBytes, 0)
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

    func testExportFilenameUsesTheValidatedImageType() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let item = try await tray.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.image.identifier,
                    filename: "screenshot.txt"
                )
            )
        )

        let resource = try await tray.assetResource(for: item)

        XCTAssertEqual(resource.exportURL.lastPathComponent, "screenshot.png")
        XCTAssertEqual(try Data(contentsOf: resource.exportURL), onePixelPNG)
    }

    func testThumbnailLoaderBoundsDecodedPixelDimensions() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let png = try XCTUnwrap(image.pngData())
        let tray = Tray(repository: InMemoryTrayRepository())
        let item = try await tray.capture(
            .image(
                ImagePayload(
                    data: png,
                    typeIdentifier: "public.png",
                    filename: "large.png"
                )
            )
        )

        let loaded = try await TrayImageLoader.thumbnail(
            for: item,
            tray: tray,
            maxPixelSize: 64
        )
        let cgImage = try XCTUnwrap(loaded.image.cgImage)

        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 64)
        XCTAssertEqual(try Data(contentsOf: loaded.originalURL), png)
    }

    func testNSItemProviderLoadsDataBackedImageRepresentation() async throws {
        let imageData = onePixelPNG
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(imageData, nil)
            return nil
        }

        let payload = try await NSItemProviderShareItem(provider: provider).loadImage()

        XCTAssertEqual(payload.data, imageData)
        XCTAssertEqual(payload.typeIdentifier, UTType.png.identifier)
    }

    func testNSItemProviderLoadsFileBackedImageRepresentation() async throws {
        let root = try temporaryRoot()
        let imageURL = root.appending(path: "file-backed.png")
        try onePixelPNG.write(to: imageURL)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: .openInPlace,
            visibility: .all
        ) { completion in
            completion(imageURL, true, nil)
            return nil
        }

        let payload = try await NSItemProviderShareItem(provider: provider).loadImage()

        XCTAssertEqual(payload.data, onePixelPNG)
        XCTAssertEqual(payload.typeIdentifier, UTType.png.identifier)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
