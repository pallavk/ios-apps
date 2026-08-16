import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImageLoadingTests: XCTestCase {
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

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
