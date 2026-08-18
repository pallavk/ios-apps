import XCTest
@testable import PocketTray

final class TrayCollectionSearchTests: XCTestCase {
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

    func testCollectionsCanBeReorderedAndPersistThatOrder() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let first = try await tray.createCollection(named: "First")
        let second = try await tray.createCollection(named: "Second")
        let third = try await tray.createCollection(named: "Third")

        try await tray.reorderCollections([third.id, first.id, second.id])
        let snapshot = try await tray.snapshot()

        XCTAssertEqual(snapshot.collections.map(\.id), [third.id, first.id, second.id])
    }

    func testDeletedCollectionCanBeUndoneWithoutLosingAssignments() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let collection = try await tray.createCollection(named: "Reference")
        let item = try await tray.capture(.text("Keep me organized"))
        _ = try await tray.assign(item.id, to: collection.id)

        let deletion = try await tray.deleteCollectionForUndo(collection.id)
        try await tray.restoreDeletedCollection(deletion)
        let snapshot = try await tray.snapshot()

        XCTAssertEqual(snapshot.collections, [collection])
        XCTAssertEqual(snapshot.recent.first?.collectionID, collection.id)
    }

    func testRenamedCollectionCanBeRestoredToItsPreviousName() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let collection = try await tray.createCollection(named: "Original")

        _ = try await tray.renameCollection(collection.id, to: "Updated")
        _ = try await tray.renameCollection(collection.id, to: collection.name)

        let snapshot = try await tray.snapshot()
        XCTAssertEqual(snapshot.collections.first?.name, "Original")
    }

    func testCollectionCoverUsesRecentNonSensitiveObjectsAndSafeFallbacks() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let text = TrayItem(id: UUID(), text: "Visible text", capturedAt: now)
        let link = TrayItem(
            id: UUID(),
            kind: .url,
            text: "https://example.com",
            capturedAt: now.addingTimeInterval(-1)
        )
        let sensitive = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: now.addingTimeInterval(-2),
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode])
        )

        let mixed = CollectionCoverContent(items: [sensitive, text, link])
        let sensitiveOnly = CollectionCoverContent(items: [sensitive])

        XCTAssertEqual(mixed.tiles.map(\.id), [text.id, link.id])
        XCTAssertEqual(mixed.fallback, nil)
        XCTAssertEqual(sensitiveOnly.tiles, [])
        XCTAssertEqual(sensitiveOnly.fallback, .sensitive)
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
}
