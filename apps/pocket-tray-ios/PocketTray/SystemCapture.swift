import AppIntents
import Foundation
import UIKit

protocol ClipboardContentReading: Sendable {
    func readCurrentContent() async -> CaptureContent
}

struct SystemClipboardContentReader: ClipboardContentReading {
    func readCurrentContent() async -> CaptureContent {
        await MainActor.run {
            SystemClipboardSupport.read(from: .general)
        }
    }
}

protocol ClipboardAvailabilityChecking: Sendable {
    func hasSupportedContent() async -> Bool
}

struct SystemClipboardAvailabilityChecker: ClipboardAvailabilityChecking {
    func hasSupportedContent() async -> Bool {
        await MainActor.run {
            SystemClipboardSupport.isAvailable(in: .general)
        }
    }
}

@MainActor
private enum SystemClipboardSupport {
    private enum Kind {
        case text
        case url
    }

    static func isAvailable(in pasteboard: UIPasteboard) -> Bool {
        supportedKind(in: pasteboard) != nil
    }

    static func read(from pasteboard: UIPasteboard) -> CaptureContent {
        switch supportedKind(in: pasteboard) {
        case .url:
            pasteboard.url.map(CaptureContent.url) ?? .unsupported
        case .text:
            pasteboard.string.map(CaptureContent.text) ?? .unsupported
        case nil:
            .unsupported
        }
    }

    private static func supportedKind(in pasteboard: UIPasteboard) -> Kind? {
        if pasteboard.hasURLs { return .url }
        if pasteboard.hasStrings { return .text }
        return nil
    }
}

enum ClipboardCaptureOutcome: Equatable, Sendable {
    case saved(TrayItem)
    case requiresSensitiveReview([SensitiveContentReason])
    case unsupported
    case failed(String)
}

struct ClipboardCaptureService: Sendable {
    let tray: Tray
    let reader: any ClipboardContentReading

    func captureCurrentContent() async -> ClipboardCaptureOutcome {
        let content = await reader.readCurrentContent()
        guard content != .unsupported else { return .unsupported }
        do {
            let prepared = try tray.prepareCapture(content)
            return .saved(try await tray.commit(prepared))
        } catch let TrayError.sensitiveContentRequiresAcknowledgment(reasons) {
            return .requiresSensitiveReview(reasons)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct SaveClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard"
    static let description = IntentDescription(
        "Deliberately save the current text or link from the clipboard to Pocket Tray."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repository: any TrayRepository
        do {
            repository = try FileTrayRepository.sharedContainer()
        } catch {
            return .result(dialog: "Pocket Tray storage is unavailable. Open the app and try again.")
        }
        let outcome = await ClipboardCaptureService(
            tray: Tray(repository: repository, analyzer: AppleContentAnalyzer()),
            reader: SystemClipboardContentReader()
        ).captureCurrentContent()
        switch outcome {
        case .saved:
            return .result(dialog: "Saved the clipboard to Pocket Tray.")
        case .requiresSensitiveReview:
            return .result(dialog: "This clipboard may contain a secret. Open Pocket Tray and use Paste to review it before saving.")
        case .unsupported:
            return .result(dialog: "The clipboard does not contain supported text or a link.")
        case .failed:
            return .result(dialog: "Pocket Tray could not save the clipboard. Open the app and try again.")
        }
    }
}

struct PocketTrayAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveClipboardIntent(),
            phrases: [
                "Save clipboard with \(.applicationName)",
                "Keep my clipboard in \(.applicationName)"
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "tray.and.arrow.down"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .blue }
}
