import XCTest
@testable import PocketTray

final class ContentAnalysisTests: XCTestCase {
    private actor ConcurrencyProbe {
        private(set) var completed = 0
        private(set) var maximumActive = 0
        private var active = 0

        func perform() async {
            active += 1
            maximumActive = max(maximumActive, active)
            try? await Task.sleep(for: .milliseconds(30))
            active -= 1
            completed += 1
        }
    }

    private actor RetryAnalyzer: ContentAnalyzing {
        let result: ContentAnalysis
        private(set) var callCount = 0

        init(result: ContentAnalysis) {
            self.result = result
        }

        func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis {
            callCount += 1
            if callCount == 1 { throw TestFailure.analysis }
            return result
        }
    }

    private actor ControlledAnalyzer: ContentAnalyzing {
        enum Mode {
            case result(ContentAnalysis)
            case failure
        }

        private let mode: Mode
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var callCount = 0

        init(mode: Mode) {
            self.mode = mode
        }

        func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis {
            callCount += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            switch mode {
            case let .result(result): return result
            case .failure: throw TestFailure.analysis
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private enum TestFailure: Error {
        case analysis
    }

    private let fixture = ContentAnalysis(
        searchableText: "Receipt from Orchard Cafe",
        languageCode: "en",
        entities: [ContentEntity(kind: .organization, value: "Orchard Cafe")],
        actions: [
            ContentAction(kind: .phone, value: "+65 6123 4567", target: "tel:+6561234567")
        ]
    )

    func testDurableCaptureIsVisibleBeforeAnalysisCompletes() async throws {
        let analyzer = ControlledAnalyzer(mode: .result(fixture))
        let tray = Tray(repository: InMemoryTrayRepository(), analyzer: analyzer)

        let captured = try await tray.capture(.text("Receipt"))
        try await waitUntil { await analyzer.callCount == 1 }
        let beforeAnalysis = try await tray.recent()

        XCTAssertEqual(beforeAnalysis.first?.id, captured.id)
        XCTAssertNil(beforeAnalysis.first?.analysis)

        await analyzer.release()
        try await waitUntil {
            let recent = try await tray.recent()
            return recent.first?.analysis == self.fixture
        }
    }

    func testAnalysisFailureLeavesOriginalObjectUsable() async throws {
        let analyzer = ControlledAnalyzer(mode: .failure)
        let tray = Tray(repository: InMemoryTrayRepository(), analyzer: analyzer)

        let captured = try await tray.capture(.text("Keep the original"))
        try await waitUntil { await analyzer.callCount == 1 }
        await analyzer.release()
        try await Task.sleep(for: .milliseconds(20))
        let recent = try await tray.recent()

        XCTAssertEqual(recent.first?.id, captured.id)
        XCTAssertEqual(recent.first?.text, "Keep the original")
        XCTAssertNil(recent.first?.analysis)
    }

    func testMissingAnalysisRetriesOnNextSnapshot() async throws {
        let analyzer = RetryAnalyzer(result: fixture)
        let tray = Tray(repository: InMemoryTrayRepository(), analyzer: analyzer)

        _ = try await tray.capture(.text("Retry locally"))
        try await waitUntil { await analyzer.callCount == 1 }
        _ = try await tray.snapshot()
        try await waitUntil {
            let recent = try await tray.recent()
            return recent.first?.analysis == self.fixture
        }

        let callCount = await analyzer.callCount
        XCTAssertGreaterThanOrEqual(callCount, 2)
    }

    func testAnalysisPersistsAcrossRepositoryRelaunch() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "tray.json")
        let analyzer = ControlledAnalyzer(mode: .result(fixture))
        let first = Tray(
            repository: FileTrayRepository(fileURL: fileURL),
            analyzer: analyzer
        )

        let item = try await first.capture(.text("Receipt"))
        try await waitUntil { await analyzer.callCount == 1 }
        await analyzer.release()
        try await waitUntil {
            let recent = try await first.recent()
            return recent.first?.analysis == self.fixture
        }

        let relaunched = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let recent = try await relaunched.recent()
        XCTAssertEqual(recent.first?.id, item.id)
        XCTAssertEqual(recent.first?.analysis, fixture)
    }

    func testSearchIndexesOCRTextEntitiesAndContextualActionValues() {
        let item = TrayItem(
            id: UUID(),
            kind: .image,
            text: "IMG_0042.PNG",
            capturedAt: Date(),
            analysis: ContentAnalysis(
                searchableText: "Handwritten sourdough recipe",
                languageCode: "en",
                entities: [ContentEntity(kind: .place, value: "Tiong Bahru")],
                actions: [
                    ContentAction(
                        kind: .phone,
                        value: "+65 6123 4567",
                        target: "tel:+6561234567"
                    )
                ]
            )
        )
        let snapshot = TraySnapshot(recent: [item], pinned: [], trash: [], collections: [])

        XCTAssertEqual(snapshot.search("sourdough").map(\.id), [item.id])
        XCTAssertEqual(snapshot.search("tiong bahru").map(\.id), [item.id])
        XCTAssertEqual(snapshot.search("6123").map(\.id), [item.id])
    }

    func testAnalysisSchedulerBoundsConcurrentWorkAcrossItems() async {
        let scheduler = ContentAnalysisScheduler(maxConcurrentOperations: 2)
        let probe = ConcurrencyProbe()

        for _ in 0..<6 {
            await scheduler.schedule(itemID: UUID()) {
                await probe.perform()
            }
        }
        await scheduler.waitUntilIdle()

        let completed = await probe.completed
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(completed, 6)
        XCTAssertEqual(maximumActive, 2)
    }

    func testSuggestedActionTitlesIdentifyEachRecognizedValue() {
        let first = ContentAction(
            kind: .url,
            value: "https://first.example/path",
            target: "https://first.example/path"
        )
        let second = ContentAction(
            kind: .url,
            value: "https://first.example/help",
            target: "https://first.example/help"
        )
        let address = ContentAction(
            kind: .address,
            value: "1 Orchard Road",
            target: "http://maps.apple.com/?q=1%20Orchard%20Road"
        )

        XCTAssertEqual(first.suggestedTitle, "Open https://first.example/path")
        XCTAssertEqual(second.suggestedTitle, "Open https://first.example/help")
        XCTAssertNotEqual(first.suggestedTitle, second.suggestedTitle)
        XCTAssertEqual(address.suggestedTitle, "Open 1 Orchard Road in Maps")
    }

    func testSearchHandlesUnicodeScriptsDiacriticsAndCharacterWidths() {
        let items = [
            TrayItem(id: UUID(), text: "Crème brûlée", capturedAt: Date()),
            TrayItem(id: UUID(), text: "مرحبا بالعالم", capturedAt: Date()),
            TrayItem(id: UUID(), text: "Ｐｏｃｋｅｔ　Ｔｒａｙ 東京", capturedAt: Date()),
            TrayItem(id: UUID(), text: "Cafe\u{301} משפחה 👨‍👩‍👧‍👦", capturedAt: Date())
        ]
        let snapshot = TraySnapshot(recent: items, pinned: [], trash: [], collections: [])

        XCTAssertEqual(snapshot.search("creme brulee").map(\.id), [items[0].id])
        XCTAssertEqual(snapshot.search("بالعالم").map(\.id), [items[1].id])
        XCTAssertEqual(snapshot.search("Pocket Tray").map(\.id), [items[2].id])
        XCTAssertEqual(snapshot.search("東京").map(\.id), [items[2].id])
        XCTAssertEqual(snapshot.search("Café").map(\.id), [items[3].id])
        XCTAssertEqual(snapshot.search("משפחה").map(\.id), [items[3].id])
        XCTAssertEqual(snapshot.search("👨‍👩‍👧‍👦").map(\.id), [items[3].id])
    }

    func testFileRepositoryRoundTripsMultilingualContentAndMetadataExactly() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "unicode-tray.json")
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let item = TrayItem(
            id: UUID(),
            text: "Cafe\u{301} — 東京 — مرحبا — 👨‍👩‍👧‍👦",
            capturedAt: capturedAt,
            title: "旅行メモ",
            note: "משפחה १२३",
            analysis: ContentAnalysis(
                searchableText: "résumé 中文 العربية",
                languageCode: "ar",
                entities: [ContentEntity(kind: .place, value: "東京")],
                actions: []
            ),
            expiresAt: capturedAt.addingTimeInterval(TrayRetention.recent)
        )
        let repository = FileTrayRepository(fileURL: fileURL)
        _ = try await repository.apply(.capture(item, assetWrite: nil))

        let relaunched = FileTrayRepository(fileURL: fileURL)
        let stored = try await relaunched.store(at: item.capturedAt)

        XCTAssertEqual(stored.items, [item])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous analysis")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
