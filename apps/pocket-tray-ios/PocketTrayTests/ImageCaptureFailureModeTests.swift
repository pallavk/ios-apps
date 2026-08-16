import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImageCaptureFailureModeTests: XCTestCase {
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
