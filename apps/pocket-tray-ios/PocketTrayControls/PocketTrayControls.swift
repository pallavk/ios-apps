import AppIntents
import SwiftUI
import WidgetKit

@main
struct PocketTrayControlsBundle: WidgetBundle {
    var body: some Widget {
        CaptureClipboardControl()
    }
}

struct CaptureClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pallavk.PocketTray.captureClipboard") {
            ControlWidgetButton(action: OpenPocketTrayForCaptureIntent()) {
                Label("Save Clipboard", systemImage: "tray.and.arrow.down")
            }
        }
        .displayName("Save Clipboard")
        .description("Open Pocket Tray to deliberately save the current clipboard.")
    }
}

struct OpenPocketTrayForCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Pocket Tray to Save Clipboard"
    static let description = IntentDescription(
        "Open Pocket Tray, where you can review and save the current clipboard."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
