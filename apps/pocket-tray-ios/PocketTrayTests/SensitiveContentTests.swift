import XCTest
@testable import PocketTray

final class SensitiveContentTests: XCTestCase {
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
}
