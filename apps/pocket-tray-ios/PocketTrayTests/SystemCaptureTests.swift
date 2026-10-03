import XCTest
import CoreTransferable
import UIKit
import UniformTypeIdentifiers
@testable import PocketTray

final class SystemCaptureTests: XCTestCase {
    private struct Reader: ClipboardContentReading {
        let content: CaptureContent
        func readCurrentContent() async -> CaptureContent { content }
    }

    private actor ClipboardRecorder: TextClipboard {
        private var copiedValues: [String] = []

        func copy(_ text: String) {
            copiedValues.append(text)
        }

        func values() -> [String] { copiedValues }
    }

    private actor SpotlightRecorder: SavedObjectSpotlightIndexing {
        private var replacements: [[UUID]] = []

        func replace(with entities: [SavedObjectEntity]) async throws {
            replacements.append(entities.map(\.id))
        }

        func recordedReplacements() -> [[UUID]] { replacements }
    }

    private actor FlakySpotlightIndex: SavedObjectSpotlightIndexing {
        private var shouldFail = true

        func replace(with entities: [SavedObjectEntity]) async throws {
            if shouldFail {
                shouldFail = false
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func testShortcutCaptureUsesTrayURLNormalizationAndDeduplication() async throws {
        let repository = InMemoryTrayRepository()
        let tray = Tray(repository: repository)
        let service = ClipboardCaptureService(
            tray: tray,
            reader: Reader(content: .text("https://example.com/path"))
        )

        let first = await service.captureCurrentContent()
        let second = await service.captureCurrentContent()

        guard case let .saved(firstItem) = first else {
            return XCTFail("Expected the shortcut capture to save")
        }
        guard case let .saved(secondItem) = second else {
            return XCTFail("Expected recapture to save")
        }
        XCTAssertEqual(firstItem.kind, .url)
        XCTAssertEqual(firstItem.id, secondItem.id)
        let recent = try await tray.recent()
        XCTAssertEqual(recent.count, 1)
    }

    func testShortcutCaptureDoesNotStoreSensitiveTextWithoutReview() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let service = ClipboardCaptureService(
            tray: tray,
            reader: Reader(content: .text("Verification code: 739201"))
        )

        let outcome = await service.captureCurrentContent()

        XCTAssertEqual(outcome, .requiresSensitiveReview([.oneTimeCode]))
        let recent = try await tray.recent()
        XCTAssertTrue(recent.isEmpty)
    }

    func testShortcutCaptureReportsUnsupportedClipboardContent() async {
        let service = ClipboardCaptureService(
            tray: Tray(repository: InMemoryTrayRepository()),
            reader: Reader(content: .unsupported)
        )

        let outcome = await service.captureCurrentContent()
        XCTAssertEqual(outcome, .unsupported)
    }

    func testClipboardPromptStaysHiddenAfterSavingUntilClipboardChanges() {
        var state = ClipboardPromptState()
        let initial = ClipboardAvailabilitySnapshot(hasSupportedContent: true, changeCount: 7)

        state.observe(initial)
        XCTAssertTrue(state.isVisible)

        state.didSaveCurrentClipboard()
        XCTAssertFalse(state.isVisible)

        state.observe(initial)
        XCTAssertFalse(state.isVisible)

        state.observe(ClipboardAvailabilitySnapshot(hasSupportedContent: true, changeCount: 8))
        XCTAssertTrue(state.isVisible)
    }

    func testSuccessfulDirectCaptureDismissesTheCurrentClipboardRevision() {
        var state = ClipboardPromptState()
        let oldClipboard = ClipboardAvailabilitySnapshot(
            hasSupportedContent: true,
            changeCount: 12
        )

        state.observe(oldClipboard)
        XCTAssertTrue(state.isVisible)

        state.dismissCurrentPrompt()
        state.observe(oldClipboard)
        XCTAssertFalse(state.isVisible)

        state.observe(
            ClipboardAvailabilitySnapshot(hasSupportedContent: true, changeCount: 13)
        )
        XCTAssertTrue(state.isVisible)
    }

    @MainActor
    func testSystemClipboardReaderPreservesOriginalImageBytes() throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        pasteboard.setData(data, forPasteboardType: UTType.png.identifier)

        let content = SystemClipboardSupport.read(from: pasteboard)

        XCTAssertEqual(
            content,
            .image(ImagePayload(data: data, typeIdentifier: UTType.png.identifier, filename: nil))
        )
    }

    @MainActor
    func testSystemClipboardReaderPreservesOriginalPDFBytes() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 120, height: 160)
        )
        let data = renderer.pdfData { context in
            context.beginPage()
            NSString(string: "Pocket Tray").draw(at: CGPoint(x: 12, y: 12))
        }
        pasteboard.setData(data, forPasteboardType: UTType.pdf.identifier)

        let content = SystemClipboardSupport.read(from: pasteboard)

        XCTAssertEqual(
            content,
            .pdf(PDFPayload(data: data, typeIdentifier: UTType.pdf.identifier, filename: nil))
        )
    }

    func testControlCaptureRequestIsConsumedExactlyOnce() {
        _ = ControlCaptureHandoff.consumeCaptureRequest()

        ControlCaptureHandoff.requestCapture()

        XCTAssertTrue(ControlCaptureHandoff.consumeCaptureRequest())
        XCTAssertFalse(ControlCaptureHandoff.consumeCaptureRequest())
    }

    func testSavedObjectOpenRequestIsConsumedExactlyOnce() {
        _ = SavedObjectOpenHandoff.consumeOpenRequest()
        let itemID = UUID()

        SavedObjectOpenHandoff.requestOpen(id: itemID)

        XCTAssertEqual(SavedObjectOpenHandoff.consumeOpenRequest(), itemID)
        XCTAssertNil(SavedObjectOpenHandoff.consumeOpenRequest())
    }

    func testSavedObjectSuggestionsPrioritizePinnedObjectsAndIncludeReusableMedia() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let olderText = TrayItem(
            id: UUID(),
            text: "Reusable text",
            capturedAt: now.addingTimeInterval(-20),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let newerLink = TrayItem(
            id: UUID(),
            kind: .url,
            text: "https://example.com/newer",
            capturedAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let pinnedText = TrayItem(
            id: UUID(),
            text: "Pinned reusable text",
            capturedAt: now.addingTimeInterval(-30),
            isPinned: true
        )
        let sensitiveText = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: now.addingTimeInterval(-5),
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode]),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let acknowledgedText = TrayItem(
            id: UUID(),
            text: "Acknowledged reusable text",
            capturedAt: now.addingTimeInterval(-8),
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode], isOverridden: true),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let image = TrayItem(
            id: UUID(),
            kind: .image,
            text: "Screenshot",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let pdf = TrayItem(
            id: UUID(),
            kind: .pdf,
            text: "Trip notes",
            capturedAt: now.addingTimeInterval(-2),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let service = SavedObjectShortcutService(
            tray: Tray(
                repository: InMemoryTrayRepository(
                    items: [olderText, newerLink, pinnedText, sensitiveText, acknowledgedText, image, pdf]
                ),
                now: { now }
            ),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let suggestions = try await service.discoverableItems()

        XCTAssertEqual(
            suggestions.map(\.id),
            [pinnedText.id, image.id, pdf.id, acknowledgedText.id, newerLink.id, olderText.id]
        )
    }

    func testSpotlightSyncIndexesOnlyCurrentlyDiscoverableObjects() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let text = TrayItem(id: UUID(), text: "Reusable", capturedAt: now, isPinned: true)
        let image = TrayItem(
            id: UUID(),
            kind: .image,
            text: "Photo",
            capturedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let sensitive = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: now,
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode]),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let shortcutService = SavedObjectShortcutService(
            tray: Tray(
                repository: InMemoryTrayRepository(items: [text, image, sensitive]),
                now: { now }
            ),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )
        let recorder = SpotlightRecorder()
        let synchronizer = SavedObjectSpotlightSynchronizer(
            shortcutService: shortcutService,
            index: recorder
        )

        try await synchronizer.synchronize(isEnabled: true)

        let replacements = await recorder.recordedReplacements()
        XCTAssertEqual(replacements, [[text.id, image.id]])
    }

    func testSpotlightSyncClearsTheIndexWhileAppLockIsEnabled() async throws {
        let shortcutService = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository()),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { true }
        )
        let recorder = SpotlightRecorder()
        let synchronizer = SavedObjectSpotlightSynchronizer(
            shortcutService: shortcutService,
            index: recorder
        )

        try await synchronizer.synchronize(isEnabled: true)

        let replacements = await recorder.recordedReplacements()
        XCTAssertEqual(replacements, [[]])
    }

    func testSpotlightSyncRemovesAnObjectAfterItMovesToTrash() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TrayItem(id: UUID(), text: "Temporary", capturedAt: now, isPinned: true)
        let tray = Tray(
            repository: InMemoryTrayRepository(items: [item]),
            now: { now }
        )
        let recorder = SpotlightRecorder()
        let synchronizer = SavedObjectSpotlightSynchronizer(
            shortcutService: SavedObjectShortcutService(
                tray: tray,
                clipboard: SystemTextClipboard(),
                isAppLockEnabled: { false }
            ),
            index: recorder
        )

        try await synchronizer.synchronize(isEnabled: true)
        _ = try await tray.moveToTrash(item.id)
        try await synchronizer.synchronize(isEnabled: true)

        let replacements = await recorder.recordedReplacements()
        XCTAssertEqual(replacements, [[item.id], []])
    }

    func testSpotlightOptOutClearsTheIndexWithoutReadingSavedObjects() async throws {
        let recorder = SpotlightRecorder()
        let synchronizer = SavedObjectSpotlightSynchronizer(
            shortcutService: SavedObjectShortcutService(
                tray: Tray(repository: InMemoryTrayRepository()),
                clipboard: SystemTextClipboard(),
                isAppLockEnabled: { true }
            ),
            index: recorder
        )

        try await synchronizer.synchronize(isEnabled: false)

        let replacements = await recorder.recordedReplacements()
        XCTAssertEqual(replacements, [[]])
    }

    func testSpotlightReconciliationRemainsPendingAfterFailureAndClearsAfterRetry() async throws {
        let suiteName = "PocketTrayTests.Spotlight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = SpotlightReconciliationState(defaults: defaults)
        let lifecycle = SavedObjectSpotlightLifecycle(
            synchronizer: SavedObjectSpotlightSynchronizer(
                shortcutService: SavedObjectShortcutService(
                    tray: Tray(repository: InMemoryTrayRepository()),
                    clipboard: SystemTextClipboard(),
                    isAppLockEnabled: { false }
                ),
                index: FlakySpotlightIndex()
            ),
            state: state
        )

        await lifecycle.synchronize(isEnabled: true)
        XCTAssertTrue(state.isPending)

        await lifecycle.synchronize(isEnabled: true)
        XCTAssertFalse(state.isPending)
    }

    func testSavedObjectEntityProvidesTransferableRepresentations() {
        func requireTransferable<T: Transferable>(_: T.Type) {}
        requireTransferable(SavedObjectEntity.self)
    }

    func testCopySavedObjectRunsInForegroundForSystemPasteboardAccess() {
        XCTAssertTrue(CopySavedObjectIntent.openAppWhenRun)
    }

    func testAppIntentResultMessagesResolveDeterministicallyInEnglish() {
        let locale = Locale(identifier: "en")

        XCTAssertEqual(
            String(
                localized: "Returned saved text from Pocket Tray.",
                bundle: .main,
                locale: locale
            ),
            "Returned saved text from Pocket Tray."
        )
        XCTAssertEqual(
            String(
                localized: "Returned a saved link from Pocket Tray.",
                bundle: .main,
                locale: locale
            ),
            "Returned a saved link from Pocket Tray."
        )
        XCTAssertEqual(
            String(
                localized: "Returned the original file from Pocket Tray.",
                bundle: .main,
                locale: locale
            ),
            "Returned the original file from Pocket Tray."
        )
        XCTAssertEqual(
            String(
                localized: "Found \(3) eligible Pocket Tray objects.",
                bundle: .main,
                locale: locale
            ),
            "Found 3 eligible Pocket Tray objects."
        )
    }

    func testSavedObjectResolutionRejectsMissingExpiredTrashedSensitiveAndMediaItems() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let available = TrayItem(
            id: UUID(),
            text: "Available",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let trashed = TrayItem(
            id: UUID(),
            text: "Trashed",
            capturedAt: now,
            state: .trash,
            trashedAt: now
        )
        let expired = TrayItem(
            id: UUID(),
            text: "Expired",
            capturedAt: now.addingTimeInterval(-TrayRetention.recent),
            expiresAt: now.addingTimeInterval(-1)
        )
        let sensitive = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: now,
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode]),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let image = TrayItem(
            id: UUID(),
            kind: .image,
            text: "Image",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let service = SavedObjectShortcutService(
            tray: Tray(
                repository: InMemoryTrayRepository(
                    items: [available, trashed, expired, sensitive, image]
                ),
                now: { now }
            ),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let resolved = try await service.resolve(id: available.id)

        XCTAssertEqual(resolved.id, available.id)
        let resolvedImage = try await service.resolve(id: image.id)
        XCTAssertEqual(resolvedImage.id, image.id)
        for unavailableID in [UUID(), trashed.id, expired.id, sensitive.id] {
            do {
                _ = try await service.resolve(id: unavailableID)
                XCTFail("Expected unavailable object \(unavailableID) to be rejected")
            } catch {
                XCTAssertEqual(error as? SavedObjectShortcutError, .itemUnavailable)
            }
        }
    }

    func testSavedObjectCopyUsesCurrentPersistedValue() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TrayItem(
            id: UUID(),
            kind: .url,
            text: "https://example.com/current",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let clipboard = ClipboardRecorder()
        let service = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository(items: [item]), now: { now }),
            clipboard: clipboard,
            isAppLockEnabled: { false }
        )

        let copied = try await service.copy(id: item.id)
        let copiedValues = await clipboard.values()

        XCTAssertEqual(copied.id, item.id)
        XCTAssertEqual(copiedValues, ["https://example.com/current"])
    }

    func testSavedObjectTextOutputReturnsCurrentTextValue() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TrayItem(
            id: UUID(),
            text: "Paste this exact text",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let service = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository(items: [item]), now: { now }),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let value = try await service.text(id: item.id)
        XCTAssertEqual(value, "Paste this exact text")
    }

    func testSavedObjectURLOutputReturnsARealURL() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TrayItem(
            id: UUID(),
            kind: .url,
            text: "https://example.com/path?q=pocket",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let service = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository(items: [item]), now: { now }),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let value = try await service.url(id: item.id)
        XCTAssertEqual(value.absoluteString, "https://example.com/path?q=pocket")
    }

    func testFindSavedObjectsSearchesEligibleCurrentMetadataInStableOrder() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = TrayItem(
            id: UUID(),
            text: "Packing checklist",
            capturedAt: now,
            title: "Bintan trip",
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let second = TrayItem(
            id: UUID(),
            kind: .pdf,
            text: "Ferry confirmation",
            capturedAt: now.addingTimeInterval(-1),
            note: "Bintan booking",
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let unrelated = TrayItem(
            id: UUID(),
            text: "Groceries",
            capturedAt: now.addingTimeInterval(-2),
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let service = SavedObjectShortcutService(
            tray: Tray(
                repository: InMemoryTrayRepository(items: [first, second, unrelated]),
                now: { now }
            ),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let matches = try await service.find("bintan")

        XCTAssertEqual(matches.map(\.id), [first.id, second.id])
    }

    func testSavedObjectFileOutputReturnsTheOriginalImageAndType() async throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let repository = InMemoryTrayRepository()
        let tray = Tray(repository: repository)
        let prepared = try tray.prepareCapture(
            .image(ImagePayload(data: data, typeIdentifier: UTType.png.identifier, filename: "pixel.png"))
        )
        let item = try await tray.commit(prepared)
        let service = SavedObjectShortcutService(
            tray: tray,
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { false }
        )

        let resource = try await service.file(id: item.id)

        XCTAssertEqual(resource.data, data)
        XCTAssertEqual(resource.asset.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(resource.exportURL.lastPathComponent, "pixel.png")
    }

    func testCopyActionRejectsMediaInsteadOfCopyingItsLabel() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let image = TrayItem(
            id: UUID(),
            kind: .image,
            text: "Screenshot",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let clipboard = ClipboardRecorder()
        let service = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository(items: [image]), now: { now }),
            clipboard: clipboard,
            isAppLockEnabled: { false }
        )

        do {
            _ = try await service.copy(id: image.id)
            XCTFail("Expected Copy Saved Object to reject media")
        } catch {
            XCTAssertEqual(error as? SavedObjectShortcutError, .incompatibleContent)
        }
        let copiedValues = await clipboard.values()
        XCTAssertTrue(copiedValues.isEmpty)
    }

    func testSavedObjectShortcutsAreUnavailableWhileAppLockIsEnabled() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = TrayItem(
            id: UUID(),
            text: "Private reusable text",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(TrayRetention.recent)
        )
        let clipboard = ClipboardRecorder()
        let service = SavedObjectShortcutService(
            tray: Tray(repository: InMemoryTrayRepository(items: [item]), now: { now }),
            clipboard: clipboard,
            isAppLockEnabled: { true }
        )

        do {
            _ = try await service.copy(id: item.id)
            XCTFail("Expected App Lock to block shortcut access")
        } catch {
            XCTAssertEqual(error as? SavedObjectShortcutError, .appLockEnabled)
        }
        let copiedValues = await clipboard.values()
        XCTAssertTrue(copiedValues.isEmpty)
    }
}
