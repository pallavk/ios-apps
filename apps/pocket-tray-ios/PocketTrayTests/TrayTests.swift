import XCTest
@testable import PocketTray

final class TrayTests: XCTestCase {
    private enum RepositoryFailure: Error, Equatable {
        case unavailable
    }

    private actor FailingTrayRepository: TrayRepository {
        func save(_ item: TrayItem) throws {
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
