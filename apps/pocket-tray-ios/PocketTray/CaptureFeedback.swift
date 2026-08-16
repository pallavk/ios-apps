import SwiftUI
import UIKit

struct FeedbackToast: View {
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.interactive(actionTitle != nil),
                    in: .rect(cornerRadius: 18)
                )
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("action-feedback")
    }
}

struct ControlCapturePrompt: View {
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Capture Clipboard", systemImage: "tray.and.arrow.down")
            } description: {
                Text("Pocket Tray reads the clipboard only after you tap Save Clipboard.")
            } actions: {
                Button("Save Clipboard", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Reads and saves supported text, links, images, or PDFs")
            }
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SystemTextClipboard: TextClipboard {
    func copy(_ text: String) async {
        await MainActor.run { UIPasteboard.general.string = text }
    }
}
