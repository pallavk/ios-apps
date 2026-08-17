import XCTest
@testable import PocketTray

final class TrayLifecycleTests: XCTestCase {
    private struct LegacyTrayItem: Codable {
        let id: UUID
        let text: String
        let capturedAt: Date
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

    func testUndoingManualTrashRestoresExactPreviousLifecycleState() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Keep my lifecycle"))
        let original = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 2_000) }
        ).setPinned(captured.id, to: true)
        let tray = Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 3_000) }
        )
        _ = try await tray.moveToTrash(original.id)

        let restored = try await tray.restoreStateFromUndo(original)
        let recent = try await tray.recent()
        let trash = try await tray.trash()

        XCTAssertEqual(restored, original)
        XCTAssertEqual(recent, [original])
        XCTAssertEqual(trash, [])
    }

    func testUndoingPinRestoresOriginalExpiry() async throws {
        let repository = InMemoryTrayRepository()
        let original = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Keep my expiry"))
        let tray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 2_000) })
        _ = try await tray.setPinned(original.id, to: true)

        let restored = try await tray.restoreStateFromUndo(original)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.expiresAt, original.expiresAt)
    }

    func testUndoingRestorePreservesOriginalTrashRetentionDate() async throws {
        let repository = InMemoryTrayRepository()
        let captured = try await Tray(
            repository: repository,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).capture(.text("Keep my trash date"))
        let trashedAt = Date(timeIntervalSince1970: 2_000)
        let originalTrashItem = try await Tray(
            repository: repository,
            now: { trashedAt }
        ).moveToTrash(captured.id)
        let tray = Tray(repository: repository, now: { Date(timeIntervalSince1970: 3_000) })
        _ = try await tray.restore(captured.id)

        let restored = try await tray.restoreStateFromUndo(originalTrashItem)

        XCTAssertEqual(restored, originalTrashItem)
        XCTAssertEqual(restored.trashedAt, trashedAt)
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
}
