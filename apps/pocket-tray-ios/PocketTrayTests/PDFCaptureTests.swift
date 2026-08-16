import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketTray

final class PDFCaptureTests: XCTestCase {
    private var onePagePDF: Data {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 240, height: 320)
        )
        return renderer.pdfData { context in
            context.beginPage()
            NSString(string: "Pocket Tray PDF").draw(at: CGPoint(x: 24, y: 24))
        }
    }

    func testPDFPayloadProducesImmutableDigestMetadata() throws {
        let pdf = onePagePDF
        let write = try PDFAssetFactory.makeWrite(
            from: PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "document.pdf")
        )

        XCTAssertEqual(write.data, pdf)
        XCTAssertEqual(write.asset.byteCount, pdf.count)
        XCTAssertEqual(write.asset.typeIdentifier, UTType.pdf.identifier)
        XCTAssertEqual(write.asset.fileExtension, "pdf")
        XCTAssertEqual(write.asset.originalFilename, "document.pdf")
        XCTAssertEqual(write.asset.digest, ImageAssetFactory.digest(of: pdf))
    }

    func testPDFPayloadAcceptsExactlyTwentyFiveMillionBytes() throws {
        var pdf = onePagePDF
        pdf.append(Data(repeating: 0, count: 25_000_000 - pdf.count))
        let write = try PDFAssetFactory.makeWrite(
            from: PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "limit.pdf")
        )
        XCTAssertEqual(write.asset.byteCount, 25_000_000)
    }

    func testPDFPayloadRejectsMoreThanTwentyFiveMillionBytes() {
        let payload = PDFPayload(
            data: Data(repeating: 0, count: 25_000_001),
            typeIdentifier: UTType.pdf.identifier,
            filename: "too-large.pdf"
        )
        XCTAssertThrowsError(try PDFAssetFactory.makeWrite(from: payload)) {
            XCTAssertEqual($0 as? TrayAssetError, .tooLarge(maximumBytes: 25_000_000))
        }
    }

    func testPDFPayloadRejectsInvalidAndNonPDFContent() {
        XCTAssertThrowsError(try PDFAssetFactory.makeWrite(
            from: PDFPayload(
                data: Data("%PDF-broken".utf8),
                typeIdentifier: UTType.pdf.identifier,
                filename: "broken.pdf"
            )
        )) {
            XCTAssertEqual($0 as? TrayAssetError, .invalidPDF)
        }
        XCTAssertThrowsError(try PDFAssetFactory.makeWrite(
            from: PDFPayload(
                data: onePagePDF,
                typeIdentifier: UTType.plainText.identifier,
                filename: "wrong.txt"
            )
        )) {
            XCTAssertEqual($0 as? TrayAssetError, .unsupportedType)
        }
    }

    func testPDFPayloadRejectsLockedPDF() throws {
        let document = try XCTUnwrap(PDFDocument(data: onePagePDF))
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: "secret",
            .ownerPasswordOption: "owner-secret"
        ]
        let locked = try XCTUnwrap(document.dataRepresentation(options: options))

        XCTAssertThrowsError(try PDFAssetFactory.makeWrite(
            from: PDFPayload(data: locked, typeIdentifier: UTType.pdf.identifier, filename: "locked.pdf")
        )) {
            XCTAssertEqual($0 as? TrayAssetError, .invalidPDF)
        }
    }

    func testOriginalPDFBytesSurviveRepositoryRelaunchAndExport() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "tray.json")
        let pdf = onePagePDF
        let first = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let item = try await first.capture(
            .pdf(PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "source.pdf"))
        )

        let second = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let resource = try await second.assetResource(for: item)
        let recent = try await second.recent()

        XCTAssertEqual(item.kind, .pdf)
        XCTAssertEqual(resource.data, pdf)
        XCTAssertEqual(try Data(contentsOf: resource.url), pdf)
        XCTAssertEqual(resource.exportURL.lastPathComponent, "source.pdf")
        XCTAssertEqual(try Data(contentsOf: resource.exportURL), pdf)
        XCTAssertEqual(recent.map(\.id), [item.id])
    }

    func testIdenticalPDFsDeduplicateAndPreserveMetadata() async throws {
        let repository = InMemoryTrayRepository()
        let pdf = onePagePDF
        let firstTray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 1_000) })
        let original = try await firstTray.capture(
            .pdf(PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "first.pdf"))
        )
        let collection = try await firstTray.createCollection(named: "Reading")
        _ = try await firstTray.edit(
            original.id,
            text: original.text,
            title: "Keep title",
            note: "Keep note",
            collectionID: collection.id
        )
        _ = try await firstTray.setPinned(original.id, to: true)

        let secondTray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 2_000) })
        let recaptured = try await secondTray.capture(
            .pdf(PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "second.pdf"))
        )

        XCTAssertEqual(recaptured.id, original.id)
        XCTAssertEqual(recaptured.kind, .pdf)
        XCTAssertEqual(recaptured.title, "Keep title")
        XCTAssertEqual(recaptured.note, "Keep note")
        XCTAssertEqual(recaptured.collectionID, collection.id)
        XCTAssertTrue(recaptured.isPinned)
        let recent = try await secondTray.recent()
        XCTAssertEqual(recent.count, 1)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
