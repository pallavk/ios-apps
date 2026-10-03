import AppIntents
import SwiftUI
import WidgetKit

@main
struct PocketTrayControlsBundle: WidgetBundle {
    var body: some Widget {
        CaptureClipboardControl()
        OpenPocketTrayControl()
    }
}

struct OpenPocketTrayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pallavk.PocketTray.open") {
            ControlWidgetButton(action: OpenPocketTrayIntent()) {
                Label("Open Pocket Tray", systemImage: "tray.full")
            }
        }
        .displayName("Open Pocket Tray")
        .description("Open your tray to find and reuse a saved object.")
    }
}

struct OpenPocketTrayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Pocket Tray"
    static let description = IntentDescription(
        "Open Pocket Tray to find, copy, or share a saved object."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct CaptureClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pallavk.PocketTray.captureClipboard") {
            ControlWidgetButton(action: OpenPocketTrayForCaptureIntent()) {
                Label("Capture Clipboard", systemImage: "tray.and.arrow.down")
            }
        }
        .displayName("Capture Clipboard")
        .description("Open Pocket Tray's private clipboard capture prompt.")
    }
}

struct OpenPocketTrayForCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Pocket Tray to Save Clipboard"
    static let description = IntentDescription(
        "Open Pocket Tray, where you can review and save the current clipboard."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        ControlCaptureHandoff.requestCapture()
        return .result()
    }
}
