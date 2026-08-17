import Foundation
import SwiftUI

@main
struct PocketTrayApp: App {
    private let tray: Tray
    private let isUITesting: Bool
    private let showsUITestClipboard: Bool
    @StateObject private var appLockController: AppLockController

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isUITesting = _isDebugAssertConfiguration() && arguments.contains("--ui-testing")
        showsUITestClipboard = arguments.contains("--ui-testing-clipboard")
        let repository: any TrayRepository
        if isUITesting {
            repository = InMemoryTrayRepository()
        } else {
            do {
                repository = try FileTrayRepository.sharedContainer()
            } catch {
                repository = UnavailableTrayRepository()
            }
        }
        tray = Tray(
            repository: repository,
            analyzer: AppleContentAnalyzer(preferredLanguages: Locale.preferredLanguages)
        )
        _appLockController = StateObject(wrappedValue: AppLockController())
    }

    var body: some Scene {
        WindowGroup {
            if isUITesting {
                RootView(
                    tray: tray,
                    clipboardAvailabilityChecker: UITestClipboardAvailabilityChecker(
                        hasSupportedContent: showsUITestClipboard
                    ),
                    clipboardContentReader: UITestClipboardContentReader(),
                    appLockController: appLockController
                )
            } else {
                AppLockGate(controller: appLockController) {
                    RootView(tray: tray, appLockController: appLockController)
                }
            }
        }
    }
}

private struct UITestClipboardAvailabilityChecker: ClipboardAvailabilityChecking {
    let hasSupportedContent: Bool

    func currentSnapshot() async -> ClipboardAvailabilitySnapshot {
        ClipboardAvailabilitySnapshot(
            hasSupportedContent: hasSupportedContent,
            changeCount: hasSupportedContent ? 1 : 0
        )
    }
}

private struct UITestClipboardContentReader: ClipboardContentReading {
    func readCurrentContent() async -> CaptureContent {
        .text("Pocket Tray UI test object")
    }
}
