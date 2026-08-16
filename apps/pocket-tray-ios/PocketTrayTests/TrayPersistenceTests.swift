import XCTest
@testable import PocketTray

final class TrayPersistenceTests: XCTestCase {
    private enum RepositoryFailure: Error, Equatable {
        case unavailable
    }

    private struct RejectingMetadataWriter: TrayMetadataWriting {
        func write(_ data: Data, to url: URL) throws {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private actor FailingTrayRepository: TrayRepository {
        func apply(_ mutation: TrayMutation) throws -> TrayMutationResult {
            throw RepositoryFailure.unavailable
        }

        func store(at date: Date) -> TrayStore {
            .empty
        }

        func resource(for asset: TrayAsset) throws -> TrayAssetResource {
            throw RepositoryFailure.unavailable
        }

        func storageReport(at date: Date) -> TrayStorageReport {
            TrayStorageReport(
                metadataBytes: 0,
                assetBytes: 0,
                unavailableAssetCount: 0,
                recoveredMetadata: false
            )
        }
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

    func testStorageReportIncludesCommittedMetadataAndWarnsOnlyBeyondFiveHundredMB() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let tray = Tray(repository: FileTrayRepository(fileURL: fileURL))
        _ = try await tray.capture(.text("Count my metadata"))

        let report = try await tray.storageReport()

        XCTAssertGreaterThan(report.metadataBytes, 0)
        XCTAssertEqual(report.assetBytes, 0)
        XCTAssertEqual(report.totalBytes, report.metadataBytes)
        XCTAssertFalse(report.exceedsWarningThreshold)
        XCTAssertFalse(
            TrayStorageReport(
                metadataBytes: 1,
                assetBytes: TrayStorageReport.warningThresholdBytes - 1,
                unavailableAssetCount: 0,
                recoveredMetadata: false
            ).exceedsWarningThreshold
        )
        XCTAssertTrue(
            TrayStorageReport(
                metadataBytes: 1,
                assetBytes: TrayStorageReport.warningThresholdBytes,
                unavailableAssetCount: 0,
                recoveredMetadata: false
            ).exceedsWarningThreshold
        )
    }

    func testCorruptedMetadataRecoversLatestCommittedStoreFromBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let firstLaunch = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let first = try await firstLaunch.capture(.text("First"))
        let second = try await firstLaunch.capture(.text("Second"))
        try Data("corrupted".utf8).write(to: fileURL)

        let relaunched = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let snapshot = try await relaunched.snapshot()
        let report = try await relaunched.storageReport()

        XCTAssertEqual(Set(snapshot.recent.map(\.id)), [first.id, second.id])
        XCTAssertTrue(report.recoveredMetadata)
    }

    func testOutOfSpaceMetadataFailureIsActionableAndPreservesPreviousCommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "tray.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let committed = try await Tray(
            repository: FileTrayRepository(fileURL: fileURL)
        ).capture(.text("Already safe"))
        let failingTray = Tray(
            repository: FileTrayRepository(
                fileURL: fileURL,
                metadataWriter: RejectingMetadataWriter()
            )
        )

        do {
            _ = try await failingTray.capture(.text("Must not appear saved"))
            XCTFail("Expected storage exhaustion")
        } catch {
            XCTAssertEqual(error as? TrayPersistenceError, .insufficientStorage)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("free up space"))
        }

        let relaunched = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recent = try await relaunched.recent()
        XCTAssertEqual(recent, [committed])

        try Data("corrupted after failed write".utf8).write(to: fileURL)
        let recovered = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recoveredRecent = try await recovered.recent()
        XCTAssertEqual(recoveredRecent, [committed])
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
