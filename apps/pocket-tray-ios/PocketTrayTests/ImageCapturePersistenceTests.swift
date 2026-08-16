import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImageCapturePersistenceTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

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
        let originalFilename = "旅行 Cafe\u{301} 👨‍👩‍👧‍👦.png"
        let first = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let item = try await first.capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: "public.png",
                    filename: originalFilename
                )
            )
        )

        let second = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let resource = try await second.assetResource(for: item)
        let recent = try await second.recent()

        XCTAssertEqual(resource.data, onePixelPNG)
        XCTAssertEqual(try Data(contentsOf: resource.url), onePixelPNG)
        XCTAssertEqual(resource.asset.originalFilename, originalFilename)
        XCTAssertEqual(resource.exportURL.lastPathComponent, originalFilename)
        XCTAssertEqual(try Data(contentsOf: resource.exportURL), onePixelPNG)
        XCTAssertEqual(recent.first?.id, item.id)
    }

    func testSharedRepositoryMigrationPreservesLegacyOriginalAssets() async throws {
        let root = try temporaryRoot()
        let legacyURL = root.appending(path: "Private/tray.json")
        let sharedURL = root.appending(path: "Shared/tray.json")
        let original = try await Tray(
            repository: FileTrayRepository(fileURL: legacyURL)
        ).capture(
            .image(
                ImagePayload(
                    data: onePixelPNG,
                    typeIdentifier: UTType.png.identifier,
                    filename: "legacy.png"
                )
            )
        )

        let migratedTray = Tray(
            repository: FileTrayRepository(
                fileURL: sharedURL,
                legacyFileURL: legacyURL
            )
        )
        let recent = try await migratedTray.recent()
        let resource = try await migratedTray.assetResource(for: original)

        XCTAssertEqual(recent.map(\.id), [original.id])
        XCTAssertEqual(resource.data, onePixelPNG)
        XCTAssertTrue(resource.url.path.hasPrefix(root.appending(path: "Shared").path))
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

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
