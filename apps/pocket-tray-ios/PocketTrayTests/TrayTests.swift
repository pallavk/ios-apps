import XCTest
@testable import PocketTray

final class TrayTests: XCTestCase {
    private enum RepositoryFailure: Error, Equatable {
        case unavailable
    }

    private actor FailingTrayRepository: TrayRepository {
        func save(_ item: TrayItem) throws -> TrayItem {
            throw RepositoryFailure.unavailable
        }

        func recent() -> [TrayItem] {
            []
        }
    }

    private actor RecordingClipboard: TextClipboard {
        private(set) var text: String?

        func copy(_ text: String) {
            self.text = text
        }
    }

    private struct StubShareProvider: ShareItemProviding {
        let url: URL?
        let text: String?
        let failsToLoad: Bool

        var canLoadURL: Bool { url != nil || failsToLoad }
        var canLoadText: Bool { text != nil }

        func loadURL() async throws -> URL {
            if failsToLoad {
                throw ShareCaptureError.unreadable
            }
            return try XCTUnwrap(url)
        }

        func loadText() async throws -> String {
            try XCTUnwrap(text)
        }
    }

    func testCapturedTextAppearsFirstInRecentObjects() async throws {
        let repository = InMemoryTrayRepository()
        let capturedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let tray = Tray(repository: repository, now: { capturedAt })

        let captured = try await tray.capture(.text("Remember this"))
        let recent = try await tray.recent()

        XCTAssertEqual(captured.text, "Remember this")
        XCTAssertEqual(captured.capturedAt, capturedAt)
        XCTAssertEqual(recent, [captured])
    }

    func testCapturedURLAppearsAsAURLObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let url = try XCTUnwrap(URL(string: "https://example.com/guide"))

        let captured = try await tray.capture(.url(url))
        let recent = try await tray.recent()

        XCTAssertEqual(captured.kind, .url)
        XCTAssertEqual(captured.text, "https://example.com/guide")
        XCTAssertEqual(recent, [captured])
    }

    func testShareProviderURLIsNormalizedThroughTheTray() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = StubShareProvider(
            url: URL(string: "https://example.com/shared"),
            text: nil,
            failsToLoad: false
        )

        let captured = try await ShareCapture(tray: tray).capture(provider)

        XCTAssertEqual(captured.kind, .url)
        XCTAssertEqual(captured.text, "https://example.com/shared")
    }

    func testShareProviderTextIsNormalizedThroughTheTray() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = StubShareProvider(
            url: nil,
            text: "Shared from another app",
            failsToLoad: false
        )

        let captured = try await ShareCapture(tray: tray).capture(provider)

        XCTAssertEqual(captured.kind, .text)
        XCTAssertEqual(captured.text, "Shared from another app")
    }

    func testUnsupportedShareProviderCreatesNoObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = StubShareProvider(url: nil, text: nil, failsToLoad: false)

        do {
            _ = try await ShareCapture(tray: tray).capture(provider)
            XCTFail("Expected unsupported provider to fail")
        } catch {
            XCTAssertEqual(error as? ShareCaptureError, .unsupported)
        }

        let recent = try await tray.recent()
        XCTAssertEqual(recent, [])
    }

    func testUnreadableShareProviderCreatesNoObject() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let provider = StubShareProvider(url: nil, text: nil, failsToLoad: true)

        do {
            _ = try await ShareCapture(tray: tray).capture(provider)
            XCTFail("Expected unreadable provider to fail")
        } catch {
            XCTAssertEqual(error as? ShareCaptureError, .unreadable)
        }

        let recent = try await tray.recent()
        XCTAssertEqual(recent, [])
    }

    func testRecapturingIdenticalContentRefreshesRecencyAndPreservesMetadata() async throws {
        let collectionID = UUID()
        let original = TrayItem(
            id: UUID(),
            kind: .text,
            text: "Keep one copy",
            createdAt: Date(timeIntervalSince1970: 500),
            capturedAt: Date(timeIntervalSince1970: 1_000),
            isPinned: true,
            title: "Important",
            note: "Use in the report",
            collectionID: collectionID,
            expiresAt: nil
        )
        let tray = Tray(
            repository: InMemoryTrayRepository(items: [original]),
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let recaptured = try await tray.capture(.text("Keep one copy"))
        let recent = try await tray.recent()

        XCTAssertEqual(recent, [recaptured])
        XCTAssertEqual(recaptured.id, original.id)
        XCTAssertEqual(recaptured.createdAt, original.createdAt)
        XCTAssertEqual(recaptured.capturedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(recaptured.isPinned)
        XCTAssertEqual(recaptured.title, "Important")
        XCTAssertEqual(recaptured.note, "Use in the report")
        XCTAssertEqual(recaptured.collectionID, collectionID)
        XCTAssertNil(recaptured.expiresAt)
    }

    func testRecaptureCollapsesDuplicatesCreatedByOlderVersions() async throws {
        let older = TrayItem(
            id: UUID(),
            text: "Legacy duplicate",
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = TrayItem(
            id: UUID(),
            text: "Legacy duplicate",
            capturedAt: Date(timeIntervalSince1970: 2_000),
            title: "Keep newer metadata"
        )
        let tray = Tray(
            repository: InMemoryTrayRepository(items: [older, newer]),
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        let recaptured = try await tray.capture(.text("Legacy duplicate"))
        let recent = try await tray.recent()

        XCTAssertEqual(recent, [recaptured])
        XCTAssertEqual(recaptured.id, newer.id)
        XCTAssertEqual(recaptured.title, "Keep newer metadata")
    }

    func testRecaptureRefreshesExpiryForAnUnpinnedObject() async throws {
        let original = TrayItem(
            id: UUID(),
            text: "Refresh me",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_500)
        )
        let recapturedAt = Date(timeIntervalSince1970: 2_000)
        let tray = Tray(
            repository: InMemoryTrayRepository(items: [original]),
            now: { recapturedAt }
        )

        let recaptured = try await tray.capture(.text("Refresh me"))

        XCTAssertEqual(
            recaptured.expiresAt,
            recapturedAt.addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    func testSharingAPreviouslyPastedURLDeduplicatesAndUpgradesItsPreview() async throws {
        let urlString = "https://example.com/same-link"
        let pastedAsText = TrayItem(
            id: UUID(),
            kind: .text,
            text: urlString,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            isPinned: true,
            title: "Preserve me"
        )
        let tray = Tray(
            repository: InMemoryTrayRepository(items: [pastedAsText]),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let url = try XCTUnwrap(URL(string: urlString))

        let recaptured = try await tray.capture(.url(url))
        let recent = try await tray.recent()

        XCTAssertEqual(recent, [recaptured])
        XCTAssertEqual(recaptured.id, pastedAsText.id)
        XCTAssertEqual(recaptured.kind, .url)
        XCTAssertTrue(recaptured.isPinned)
        XCTAssertEqual(recaptured.title, "Preserve me")
    }

    func testCapturedTextSurvivesRepositoryRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let captured = try await firstLaunch.capture(.text("Still here"))

        let secondLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recent = try await secondLaunch.recent()

        XCTAssertEqual(recent, [captured])
    }

    func testPersistenceReadsFromDirectoryContainingSpaces() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }

        let firstLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let captured = try await firstLaunch.capture(.text("Path with a space"))

        let secondLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recent = try await secondLaunch.recent()

        XCTAssertEqual(recent, [captured])
    }

    func testSharedRepositoryMigratesExistingPrivateObjects() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let legacyURL = root.appending(path: "Private/tray.json")
        let sharedURL = root.appending(path: "Shared/tray.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let privateRepository = FileTrayRepository(fileURL: legacyURL)
        let captured = try await Tray(repository: privateRepository).capture(.text("Migrate me"))

        let sharedRepository = FileTrayRepository(
            fileURL: sharedURL,
            legacyFileURL: legacyURL
        )
        let migrated = try await Tray(repository: sharedRepository).recent()
        let relaunched = try await Tray(
            repository: FileTrayRepository(fileURL: sharedURL)
        ).recent()

        XCTAssertEqual(migrated, [captured])
        XCTAssertEqual(relaunched, [captured])
    }

    func testRecentObjectsAreNewestFirst() async throws {
        let repository = InMemoryTrayRepository()
        let earlierTray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let laterTray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let earlier = try await earlierTray.capture(.text("Earlier"))
        let later = try await laterTray.capture(.text("Later"))
        let recent = try await laterTray.recent()

        XCTAssertEqual(recent, [later, earlier])
    }

    func testBlankClipboardTextIsRejected() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())

        do {
            _ = try await tray.capture(.text("  \n "))
            XCTFail("Expected blank clipboard text to be rejected")
        } catch {
            XCTAssertEqual(error as? TrayError, .emptyText)
        }

        let recent = try await tray.recent()
        XCTAssertEqual(recent, [])
    }

    func testUnsupportedClipboardContentIsRejected() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())

        do {
            _ = try await tray.capture(.unsupported)
            XCTFail("Expected unsupported clipboard content to be rejected")
        } catch {
            XCTAssertEqual(error as? TrayError, .unsupportedContent)
        }

        let recent = try await tray.recent()
        XCTAssertEqual(recent, [])
    }

    func testReusingAnItemCopiesItsText() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let clipboard = RecordingClipboard()
        let item = try await tray.capture(.text("Paste me"))

        try await tray.reuse(item, using: clipboard)

        let copiedText = await clipboard.text
        XCTAssertEqual(copiedText, "Paste me")
    }

    func testPersistenceFailureIsReportedWithoutARecentObject() async throws {
        let tray = Tray(repository: FailingTrayRepository())

        do {
            _ = try await tray.capture(.text("Do not pretend this saved"))
            XCTFail("Expected the persistence error to be reported")
        } catch {
            XCTAssertEqual(error as? RepositoryFailure, .unavailable)
        }

        let recent = try await tray.recent()
        XCTAssertEqual(recent, [])
    }
}
