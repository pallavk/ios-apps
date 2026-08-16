import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class ImagePayloadTests: XCTestCase {
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
}
