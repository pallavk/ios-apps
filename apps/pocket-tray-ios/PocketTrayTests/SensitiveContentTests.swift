import XCTest
@testable import PocketTray

final class SensitiveContentTests: XCTestCase {
    private struct ImmediateAnalyzer: ContentAnalyzing {
        let result: ContentAnalysis
        func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis { result }
    }

    private struct TextShareProvider: ShareItemProviding {
        let text: String
        var canLoadURL: Bool { false }
        var canLoadText: Bool { true }
        func loadURL() async throws -> URL { throw ShareCaptureError.unsupported }
        func loadText() async throws -> String { text }
    }

    private let classifier = DeterministicSensitiveContentClassifier()

    func testContextualOneTimeCodesAreFlaggedWithoutFlaggingOrdinaryNumbers() {
        XCTAssertEqual(
            classifier.reasons(in: "Your verification code is 482913"),
            [.oneTimeCode]
        )
        XCTAssertEqual(classifier.reasons(in: "OTP: 1234"), [.oneTimeCode])
        XCTAssertEqual(classifier.reasons(in: "Order 482913 ships tomorrow"), [])
        XCTAssertEqual(classifier.reasons(in: "Call +65 6123 4567"), [])
    }

    func testOnlyLuhnValidNonRepeatedCardCandidatesAreFlagged() {
        XCTAssertEqual(
            classifier.reasons(in: "Card 4242 4242 4242 4242"),
            [.paymentCard]
        )
        XCTAssertEqual(classifier.reasons(in: "Card 4242 4242 4242 4243"), [])
        XCTAssertEqual(classifier.reasons(in: "0000 0000 0000 0000"), [])
        XCTAssertEqual(classifier.reasons(in: "Reference 123456789012"), [])
    }

    func testRecognizablePrivateKeyMarkersAreFlagged() {
        XCTAssertEqual(
            classifier.reasons(in: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc"),
            [.privateKey]
        )
        XCTAssertEqual(
            classifier.reasons(in: "-----BEGIN EC PRIVATE KEY-----\nabc"),
            [.privateKey]
        )
        XCTAssertEqual(classifier.reasons(in: "public key: ssh-ed25519 AAAA"), [])
    }

    func testFlaggedCaptureRequiresExplicitAcknowledgmentBeforeStorage() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let prepared = try tray.prepareCapture(.text("Your OTP is 739201"))

        do {
            _ = try await tray.commit(prepared)
            XCTFail("Expected sensitive-content acknowledgment")
        } catch {
            XCTAssertEqual(
                error as? TrayError,
                .sensitiveContentRequiresAcknowledgment([.oneTimeCode])
            )
        }
        let beforeAcknowledgment = try await tray.recent()
        XCTAssertTrue(beforeAcknowledgment.isEmpty)

        let saved = try await tray.commit(
            prepared,
            acknowledgingSensitiveContent: true
        )
        XCTAssertEqual(saved.sensitivity?.reasons, [.oneTimeCode])
        XCTAssertTrue(saved.protectsSensitivePreview)
    }

    func testSensitiveShareIsRejectedForDeliberateInAppReview() async throws {
        let provider = TextShareProvider(text: "Verification code: 739201")
        let result = try await ShareCapture(
            tray: Tray(repository: InMemoryTrayRepository())
        ).captureAll([provider])

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected, [.sensitive])
    }

    func testOCRDerivedSecretProtectsImageAfterDurableCapture() async throws {
        let analyzer = ImmediateAnalyzer(
            result: ContentAnalysis(
                searchableText: "Payment card 4242 4242 4242 4242",
                languageCode: "en",
                entities: [],
                actions: []
            )
        )
        let tray = Tray(repository: InMemoryTrayRepository(), analyzer: analyzer)
        let image = ImagePayload(
            data: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!,
            typeIdentifier: "public.png",
            filename: "receipt.png"
        )

        let captured = try await tray.capture(.image(image))
        XCTAssertNil(captured.sensitivity)
        try await waitUntil {
            let recent = try await tray.recent()
            return recent.first?.sensitivity?.reasons == [.paymentCard]
        }
        let recent = try await tray.recent()
        let protected = try XCTUnwrap(recent.first)

        XCTAssertEqual(protected.id, captured.id)
        XCTAssertEqual(protected.asset, captured.asset)
        XCTAssertEqual(protected.state, .recent)
        XCTAssertTrue(protected.protectsSensitivePreview)
    }

    func testFalsePositiveOverridePersistsAndTextChangeReclassifies() async throws {
        let root = try temporaryRoot()
        let fileURL = root.appending(path: "tray.json")
        let tray = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let prepared = try tray.prepareCapture(.text("OTP: 739201"))
        let saved = try await tray.commit(prepared, acknowledgingSensitiveContent: true)

        let overridden = try await tray.setSensitivityOverridden(saved.id, to: true)
        XCTAssertFalse(overridden.protectsSensitivePreview)
        let relaunched = Tray(repository: FileTrayRepository(fileURL: fileURL))
        let relaunchedItems = try await relaunched.recent()
        XCTAssertEqual(relaunchedItems.first?.sensitivity?.isOverridden, true)

        let edited = try await relaunched.edit(
            saved.id,
            text: "Ordinary shopping note",
            title: nil,
            note: nil
        )
        XCTAssertNil(edited.sensitivity)
        XCTAssertFalse(edited.protectsSensitivePreview)
    }

    func testEditingInASecretRequiresAcknowledgmentAndKeepsOriginalUntilConfirmed() async throws {
        let tray = Tray(repository: InMemoryTrayRepository())
        let original = try await tray.capture(.text("Ordinary note"))

        do {
            _ = try await tray.edit(
                original.id,
                text: "Verification code: 739201",
                title: nil,
                note: nil
            )
            XCTFail("Expected sensitive edit acknowledgment")
        } catch {
            XCTAssertEqual(
                error as? TrayError,
                .sensitiveContentRequiresAcknowledgment([.oneTimeCode])
            )
        }
        let beforeAcknowledgment = try await tray.recent()
        XCTAssertEqual(beforeAcknowledgment.first?.text, "Ordinary note")

        let edited = try await tray.edit(
            original.id,
            text: "Verification code: 739201",
            title: nil,
            note: nil,
            acknowledgingSensitiveContent: true
        )
        XCTAssertEqual(edited.sensitivity?.reasons, [.oneTimeCode])
        XCTAssertTrue(edited.protectsSensitivePreview)
    }

    func testSensitivePreviewSessionRequiresRevealAndResetsWhenAppLeavesForeground() {
        let protected = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: Date(),
            sensitivity: SensitivityAssessment(reasons: [.oneTimeCode])
        )
        var session = SensitivePreviewSession()

        XCTAssertFalse(session.allowsContentAccess(to: protected))
        session.reveal(protected.id)
        XCTAssertTrue(session.allowsContentAccess(to: protected))
        session.hide(protected.id)
        XCTAssertFalse(session.allowsContentAccess(to: protected))

        session.reveal(protected.id)
        session.endForegroundSession()
        XCTAssertFalse(session.allowsContentAccess(to: protected))
    }

    func testSensitivePreviewSessionAllowsOrdinaryAndOverriddenContent() {
        let ordinary = TrayItem(id: UUID(), text: "Shopping list", capturedAt: Date())
        let overridden = TrayItem(
            id: UUID(),
            text: "Verification code: 739201",
            capturedAt: Date(),
            sensitivity: SensitivityAssessment(
                reasons: [.oneTimeCode],
                isOverridden: true
            )
        )
        let session = SensitivePreviewSession()

        XCTAssertTrue(session.allowsContentAccess(to: ordinary))
        XCTAssertTrue(session.allowsContentAccess(to: overridden))
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
        XCTFail("Timed out waiting for sensitivity analysis")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
