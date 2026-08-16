import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketTray

final class PDFCaptureTests: XCTestCase {
    @MainActor
    private final class CommitRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private struct PDFShareProvider: ShareItemProviding {
        let payload: PDFPayload
        let loadError: ShareCaptureError?

        var canLoadPDF: Bool { true }
        var canLoadURL: Bool { false }
        var canLoadText: Bool { false }

        func loadPDF() async throws -> PDFPayload {
            if let loadError { throw loadError }
            return payload
        }

        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { throw ShareCaptureError.unsupported }
    }

    private struct TextShareProvider: ShareItemProviding {
        let text: String
        var canLoadURL: Bool { false }
        var canLoadText: Bool { true }
        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { text }
    }

    private struct URLShareProvider: ShareItemProviding {
        let url: URL
        var canLoadURL: Bool { true }
        var canLoadText: Bool { false }
        func loadURL() async throws -> URL { url }
        func loadText() async throws -> String { throw ShareCaptureError.unsupported }
    }

    private struct UnsupportedShareProvider: ShareItemProviding {
        var canLoadURL: Bool { false }
        var canLoadText: Bool { false }
        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { throw ShareCaptureError.unsupported }
    }

    private struct CancellationAwarePDFProvider: ShareItemProviding {
        var canLoadPDF: Bool { true }
        var canLoadURL: Bool { false }
        var canLoadText: Bool { false }
        func loadPDF() async throws -> PDFPayload {
            try await Task.sleep(for: .seconds(30))
            throw ShareCaptureError.unreadable
        }
        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { throw ShareCaptureError.unsupported }
    }

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
                data: Data(),
                typeIdentifier: UTType.pdf.identifier,
                filename: "empty.pdf"
            )
        )) {
            XCTAssertEqual($0 as? TrayAssetError, .invalidPDF)
        }
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

    func testShareCaptureLoadsPDFRepresentation() async throws {
        let pdf = onePagePDF
        let tray = Tray(repository: InMemoryTrayRepository())

        let item = try await ShareCapture(tray: tray).capture(
            PDFShareProvider(
                payload: PDFPayload(
                    data: pdf,
                    typeIdentifier: UTType.pdf.identifier,
                    filename: "shared.pdf"
                ),
                loadError: nil
            )
        )

        XCTAssertEqual(item.kind, .pdf)
        let resource = try await tray.assetResource(for: item)
        XCTAssertEqual(resource.data, pdf)
    }

    func testMultiObjectShareCreatesOneObjectPerAcceptedInputInOrder() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let pdf = onePagePDF
        let providers: [any ShareItemProviding] = [
            PDFShareProvider(
                payload: PDFPayload(
                    data: pdf,
                    typeIdentifier: UTType.pdf.identifier,
                    filename: "first.pdf"
                ),
                loadError: nil
            ),
            TextShareProvider(text: "Second object")
        ]

        let result = try await ShareCapture(tray: tray).captureAll(providers)
        let recent = try await tray.recent()

        XCTAssertEqual(result.accepted.map(\.kind), [.pdf, .text])
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertEqual(Set(recent.map(\.id)), Set(result.accepted.map(\.id)))
    }

    func testMixedShareKeepsAcceptedInputsAndReportsEveryRejection() async throws {
        let root = try temporaryRoot()
        let tray = Tray(
            repository: FileTrayRepository(fileURL: root.appending(path: "tray.json"))
        )
        let pdf = onePagePDF
        let providers: [any ShareItemProviding] = [
            TextShareProvider(text: "Keep me"),
            UnsupportedShareProvider(),
            TextShareProvider(text: "   "),
            URLShareProvider(url: URL(fileURLWithPath: "/tmp/not-web")),
            PDFShareProvider(
                payload: PDFPayload(
                    data: pdf,
                    typeIdentifier: UTType.pdf.identifier,
                    filename: "unreadable.pdf"
                ),
                loadError: .unreadable
            ),
            PDFShareProvider(
                payload: PDFPayload(
                    data: Data(repeating: 0, count: 25_000_001),
                    typeIdentifier: UTType.pdf.identifier,
                    filename: "large.pdf"
                ),
                loadError: nil
            )
        ]

        let result = try await ShareCapture(tray: tray).captureAll(providers)
        let recent = try await tray.recent()

        XCTAssertEqual(result.accepted.map(\.text), ["Keep me"])
        XCTAssertEqual(
            result.rejected,
            [.unsupported, .unreadable, .unsupported, .unreadable, .oversized]
        )
        XCTAssertEqual(recent.map(\.id), result.accepted.map(\.id))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "assets").path)
        )
    }

    func testNSItemProviderLoadsDataAndFileBackedPDFRepresentations() async throws {
        let pdf = onePagePDF
        let dataProvider = NSItemProvider()
        dataProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            visibility: .all
        ) { completion in
            completion(pdf, nil)
            return nil
        }
        let dataPayload = try await NSItemProviderShareItem(provider: dataProvider).loadPDF()
        XCTAssertEqual(dataPayload.data, pdf)

        let root = try temporaryRoot()
        let fileURL = root.appending(path: "file-backed.pdf")
        try pdf.write(to: fileURL)
        let fileProvider = NSItemProvider()
        fileProvider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            fileOptions: .openInPlace,
            visibility: .all
        ) { completion in
            completion(fileURL, true, nil)
            return nil
        }
        let filePayload = try await NSItemProviderShareItem(provider: fileProvider).loadPDF()
        XCTAssertEqual(filePayload.data, pdf)
    }

    func testNSItemProviderRejectsOversizedFileBeforePayloadCreation() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "oversized.pdf")
        try Data(repeating: 0, count: 25_000_001).write(to: fileURL)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            fileOptions: .openInPlace,
            visibility: .all
        ) { completion in
            completion(fileURL, true, nil)
            return nil
        }

        do {
            _ = try await NSItemProviderShareItem(provider: provider).loadPDF()
            XCTFail("Expected the provider boundary to reject the file")
        } catch {
            XCTAssertEqual(
                error as? TrayAssetError,
                .tooLarge(maximumBytes: 25_000_000)
            )
        }
    }

    func testRejectedProviderDoesNotEnterTheCommitPhase() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let recorder = await MainActor.run { CommitRecorder() }
        let provider = PDFShareProvider(
            payload: PDFPayload(
                data: Data(repeating: 0, count: 25_000_001),
                typeIdentifier: UTType.pdf.identifier,
                filename: "too-large.pdf"
            ),
            loadError: nil
        )

        let result = try await ShareCapture(tray: tray).captureAll(
            [provider],
            willCommit: { recorder.record() }
        )
        let commitCount = await MainActor.run { recorder.count }

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, [.oversized])
        XCTAssertEqual(commitCount, 0)
    }

    func testProviderCancellationCancelsTheWholeBatch() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let task = Task {
            try await ShareCapture(tray: tray).captureAll(
                [CancellationAwarePDFProvider()]
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the batch to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testPDFThumbnailIsBoundedAndOriginalRemainsExportable() async throws {
        let pdf = onePagePDF
        let tray = Tray(repository: InMemoryTrayRepository())
        let item = try await tray.capture(
            .pdf(PDFPayload(data: pdf, typeIdentifier: UTType.pdf.identifier, filename: "preview.pdf"))
        )

        let thumbnail = try await TrayPDFLoader.thumbnail(
            for: item,
            tray: tray,
            size: CGSize(width: 80, height: 100)
        )
        let loaded = try await TrayPDFLoader.load(for: item, tray: tray)

        XCTAssertLessThanOrEqual(thumbnail.image.size.width, 80)
        XCTAssertLessThanOrEqual(thumbnail.image.size.height, 100)
        XCTAssertEqual(thumbnail.pageCount, 1)
        XCTAssertEqual(loaded.document.pageCount, 1)
        XCTAssertEqual(try Data(contentsOf: loaded.exportURL), pdf)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
