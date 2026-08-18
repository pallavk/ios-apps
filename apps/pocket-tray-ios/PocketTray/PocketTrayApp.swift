import Foundation
import SwiftUI

@main
struct PocketTrayApp: App {
    private let tray: Tray
    private let isUITesting: Bool
    private let showsUITestClipboard: Bool
    private let usesUITestAccessibilitySize: Bool
    @StateObject private var appLockController: AppLockController

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isUITesting = _isDebugAssertConfiguration() && arguments.contains("--ui-testing")
        if isUITesting {
            UserDefaults.standard.removeObject(forKey: "PocketTray.searchHistory")
        }
        showsUITestClipboard = arguments.contains("--ui-testing-clipboard")
        usesUITestAccessibilitySize = arguments.contains("--ui-testing-accessibility-size")
        let repository: any TrayRepository
        if isUITesting {
            repository = arguments.contains("--ui-testing-content")
                ? PocketTrayUITestFixtures.repository()
                : InMemoryTrayRepository()
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
                uiTestRoot
            } else {
                AppLockGate(controller: appLockController) {
                    RootView(tray: tray, appLockController: appLockController)
                }
            }
        }
    }

    @ViewBuilder
    private var uiTestRoot: some View {
        let root = RootView(
            tray: tray,
            clipboardAvailabilityChecker: UITestClipboardAvailabilityChecker(
                hasSupportedContent: showsUITestClipboard
            ),
            clipboardContentReader: UITestClipboardContentReader(),
            appLockController: appLockController
        )
        if usesUITestAccessibilitySize {
            root.dynamicTypeSize(.accessibility3)
        } else {
            root
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
