import XCTest
@testable import PocketTray

final class TrayTests: XCTestCase {
    private struct LegacyTrayItem: Codable {
        let id: UUID
        let text: String
        let capturedAt: Date
    }

    private enum RepositoryFailure: Error, Equatable {
        case unavailable
    }

    private actor FailingTrayRepository: TrayRepository {
        func apply(_ mutation: TrayMutation) throws -> TrayMutationResult {
            throw RepositoryFailure.unavailable
        }

        func store(at date: Date) -> TrayStore {
            .empty
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

    func testEditingTextAndMetadataPreservesDeduplicationIdentity() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Original capture"))
        let tray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let edited = try await tray.edit(
            captured.id,
            text: "Edited text",
            title: "Reference",
            note: "Keep this wording",
            collectionID: nil
        )
        let recaptured = try await tray.capture(.text("Original capture"))
        let recapturedEditedValue = try await tray.capture(.text("Edited text"))
        let recent = try await tray.recent()

        XCTAssertEqual(edited.id, captured.id)
        XCTAssertEqual(recaptured.id, captured.id)
        XCTAssertEqual(recapturedEditedValue.id, captured.id)
        XCTAssertEqual(recaptured.text, "Edited text")
        XCTAssertEqual(recaptured.title, "Reference")
        XCTAssertEqual(recaptured.note, "Keep this wording")
        XCTAssertEqual(recent, [recaptured])
    }

    func testCreatingACollectionAddsItToTheTraySnapshot() async throws {
        let tray = Tray(
            repository: InMemoryTrayRepository(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let collection = try await tray.createCollection(named: "  Work  ")
        let snapshot = try await tray.snapshot()

        XCTAssertEqual(collection.name, "Work")
        XCTAssertEqual(collection.createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(snapshot.collections, [collection])
    }

    func testAssigningACollectionDoesNotChangePinState() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let collection = try await tray.createCollection(named: "Projects")
        let captured = try await tray.capture(.text("Launch notes"))
        _ = try await tray.setPinned(captured.id, to: true)

        let assigned = try await tray.assign(captured.id, to: collection.id)

        XCTAssertEqual(assigned.collectionID, collection.id)
        XCTAssertTrue(assigned.isPinned)
    }

    func testRenamingAndDeletingACollectionPreservesItsObjects() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let collection = try await tray.createCollection(named: "Drafts")
        let captured = try await tray.capture(.text("Keep the object"))
        _ = try await tray.assign(captured.id, to: collection.id)

        let renamed = try await tray.renameCollection(collection.id, to: "Reference")
        try await tray.deleteCollection(collection.id)
        let snapshot = try await tray.snapshot()

        XCTAssertEqual(renamed.name, "Reference")
        XCTAssertEqual(snapshot.collections, [])
        XCTAssertEqual(snapshot.recent.count, 1)
        XCTAssertNil(snapshot.recent.first?.collectionID)
    }

    func testSearchCoversTextURLsTitlesNotesAndCollectionNames() async throws {
        let repository = InMemoryTrayRepository()
        let tray = Tray(repository: repository)
        let collection = try await tray.createCollection(named: "Finance")
        let textItem = try await tray.capture(.text("Meeting transcript"))
        _ = try await tray.edit(
            textItem.id,
            text: textItem.text,
            title: "Quarterly review",
            note: "Project Lantern"
        )
        _ = try await tray.assign(textItem.id, to: collection.id)
        let url = try XCTUnwrap(URL(string: "https://example.com/guides"))
        let urlItem = try await tray.capture(.url(url))

        let byText = try await tray.search("transcript")
        let byURL = try await tray.search("EXAMPLE.COM")
        let byTitle = try await tray.search("quarterly")
        let byNote = try await tray.search("lantern")
        let byCollection = try await tray.search("finance")

        XCTAssertEqual(byText.map(\.id), [textItem.id])
        XCTAssertEqual(byURL.map(\.id), [urlItem.id])
        XCTAssertEqual(byTitle.map(\.id), [textItem.id])
        XCTAssertEqual(byNote.map(\.id), [textItem.id])
        XCTAssertEqual(byCollection.map(\.id), [textItem.id])
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

    func testPinningAnObjectPreventsExpiry() async throws {
        let repository = InMemoryTrayRepository()
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let captured = try await Tray(
            repository: repository,
            now: { capturedAt }
        ).capture(.text("Keep forever"))
        let tray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let pinned = try await tray.setPinned(captured.id, to: true)
        let farFuture = Date(timeIntervalSince1970: 2_000 + 30 * 24 * 60 * 60)
        let recent = try await Tray(
            repository: repository,
            now: { farFuture }
        ).recent()

        XCTAssertTrue(pinned.isPinned)
        XCTAssertNil(pinned.expiresAt)
        XCTAssertEqual(recent, [pinned])
    }

    func testUnpinnedObjectMovesToTrashAtItsExpiry() async throws {
        let repository = InMemoryTrayRepository()
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let captured = try await Tray(
            repository: repository,
            now: { capturedAt }
        ).capture(.text("Temporary"))
        let expiry = try XCTUnwrap(captured.expiresAt)
        let trayAtExpiry = Tray(repository: repository, now: { expiry })

        let recent = try await trayAtExpiry.recent()
        let trash = try await trayAtExpiry.trash()

        XCTAssertEqual(recent, [])
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash.first?.id, captured.id)
        XCTAssertEqual(trash.first?.trashedAt, expiry)
    }

    func testLegacyUnpinnedObjectWithoutExpiryStillExpiresAfterSevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let legacy = LegacyTrayItem(id: UUID(), text: "Legacy temporary", capturedAt: capturedAt)
        try JSONEncoder().encode([legacy]).write(to: fileURL)
        let expiry = capturedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let tray = Tray(
            repository: FileTrayRepository(fileURL: fileURL),
            now: { expiry }
        )

        let recent = try await tray.recent()
        let trash = try await tray.trash()

        XCTAssertEqual(recent, [])
        XCTAssertEqual(trash.map(\.id), [legacy.id])
    }

    func testExpiredObjectCannotBePinnedFromStaleUI() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Too late to pin"))
        let expiry = try XCTUnwrap(captured.expiresAt)
        let trayAtExpiry = Tray(repository: repository, now: { expiry })

        do {
            _ = try await trayAtExpiry.setPinned(captured.id, to: true)
            XCTFail("Expected the expired object to move to Trash before pinning")
        } catch {
            XCTAssertEqual(error as? TrayError, .itemNotFound)
        }

        let trash = try await trayAtExpiry.trash()
        XCTAssertEqual(trash.map(\.id), [captured.id])
        XCTAssertFalse(try XCTUnwrap(trash.first).isPinned)
    }

    func testManualDeletionMovesObjectToRecoverableTrash() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Delete carefully"))
        let deletionTime = Date(timeIntervalSince1970: 2_000)
        let tray = Tray(repository: repository, now: { deletionTime })

        let deleted = try await tray.moveToTrash(captured.id)
        let recent = try await tray.recent()
        let trash = try await tray.trash()

        XCTAssertEqual(deleted.state, .trash)
        XCTAssertEqual(deleted.trashedAt, deletionTime)
        XCTAssertEqual(recent, [])
        XCTAssertEqual(trash, [deleted])
    }

    func testRestoringFromTrashStartsAFreshExpiryPeriod() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Bring me back"))
        _ = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        ).moveToTrash(captured.id)
        let restoredAt = Date(timeIntervalSince1970: 3_000)
        let tray = Tray(repository: repository, now: { restoredAt })

        let restored = try await tray.restore(captured.id)
        let trash = try await tray.trash()

        XCTAssertEqual(restored.id, captured.id)
        XCTAssertEqual(restored.state, .recent)
        XCTAssertNil(restored.trashedAt)
        XCTAssertFalse(restored.isPinned)
        XCTAssertEqual(
            restored.expiresAt,
            restoredAt.addingTimeInterval(7 * 24 * 60 * 60)
        )
        XCTAssertEqual(trash, [])
    }

    func testPermanentlyDeletingATrashedObjectRemovesItImmediately() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Remove completely"))
        let tray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        _ = try await tray.moveToTrash(captured.id)

        try await tray.deletePermanently(captured.id)

        let trash = try await tray.trash()
        XCTAssertEqual(trash, [])
    }

    func testTrashIsAutomaticallyPurgedAfterSevenDays() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Temporary trash"))
        let trashedAt = Date(timeIntervalSince1970: 2_000)
        _ = try await Tray(
            repository: repository,
            now: { trashedAt }
        ).moveToTrash(captured.id)
        let purgeDate = trashedAt.addingTimeInterval(7 * 24 * 60 * 60)

        let trash = try await Tray(
            repository: repository,
            now: { purgeDate }
        ).trash()

        XCTAssertEqual(trash, [])
    }

    func testUnpinningStartsAFreshSevenDayExpiryPeriod() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Pinned for now"))
        _ = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        ).setPinned(captured.id, to: true)
        let unpinnedAt = Date(timeIntervalSince1970: 10_000)

        let unpinned = try await Tray(
            repository: repository,
            now: { unpinnedAt }
        ).setPinned(captured.id, to: false)

        XCTAssertFalse(unpinned.isPinned)
        XCTAssertEqual(
            unpinned.expiresAt,
            unpinnedAt.addingTimeInterval(7 * 24 * 60 * 60)
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

    func testLifecycleStateSurvivesRepositoryRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let captured = try await Tray(
            repository: FileTrayRepository(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Persist my lifecycle"))
        _ = try await Tray(
            repository: FileTrayRepository(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 2_000) }
        ).moveToTrash(captured.id)

        let relaunchedTray = Tray(
            repository: FileTrayRepository(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 3_000) }
        )
        let recent = try await relaunchedTray.recent()
        let trash = try await relaunchedTray.trash()

        XCTAssertEqual(recent, [])
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash.first?.id, captured.id)
        XCTAssertEqual(trash.first?.trashedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testEditingAndCollectionsSurviveRepositoryRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let firstLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let collection = try await firstLaunch.createCollection(named: "Reference")
        let captured = try await firstLaunch.capture(.text("Initial text"))
        _ = try await firstLaunch.edit(
            captured.id,
            text: "Edited text",
            title: "Saved title",
            note: "Saved note",
            collectionID: collection.id
        )

        let secondLaunch = Tray(
            repository: FileTrayRepository(fileURL: fileURL)
        )
        let snapshot = try await secondLaunch.snapshot()
        let recaptured = try await secondLaunch.capture(.text("Initial text"))
        let recapturedEditedValue = try await secondLaunch.capture(.text("Edited text"))
        let finalSnapshot = try await secondLaunch.snapshot()

        XCTAssertEqual(snapshot.collections, [collection])
        XCTAssertEqual(snapshot.recent.first?.text, "Edited text")
        XCTAssertEqual(snapshot.recent.first?.title, "Saved title")
        XCTAssertEqual(snapshot.recent.first?.note, "Saved note")
        XCTAssertEqual(snapshot.recent.first?.collectionID, collection.id)
        XCTAssertEqual(recaptured.id, captured.id)
        XCTAssertEqual(recapturedEditedValue.id, captured.id)
        XCTAssertEqual(recaptured.text, "Edited text")
        XCTAssertEqual(finalSnapshot.recent.count, 1)
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
