import SwiftUI
import UIKit

enum CaptureActionMode: Equatable {
    case add
    case saveClipboard

    init(clipboardPromptIsVisible: Bool) {
        self = clipboardPromptIsVisible ? .saveClipboard : .add
    }
}

struct CaptureBarActions {
    let saveClipboard: () -> Void
    let newText: () -> Void
    let choosePhoto: () -> Void
    let takePhoto: () -> Void
}

struct PocketTrayCaptureBar: View {
    let mode: CaptureActionMode
    let isReadingClipboard: Bool
    let isLoadingDirectCapture: Bool
    let isCompact: Bool
    let actions: CaptureBarActions

    var body: some View {
        HStack(spacing: 10) {
            switch mode {
            case .add:
                Menu {
                    directCaptureMenuItems
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                        .frame(maxWidth: isCompact ? nil : .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingDirectCapture)
                .accessibilityIdentifier("primary-capture-action")
                .accessibilityHint("Adds text or a photo directly to Pocket Tray")
            case .saveClipboard:
                Button(action: actions.saveClipboard) {
                    if isReadingClipboard {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Save Clipboard", systemImage: "clipboard")
                            .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                            .frame(maxWidth: isCompact ? nil : .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isReadingClipboard || isLoadingDirectCapture)
                .accessibilityIdentifier("primary-capture-action")
                .accessibilityHint("Reads and saves the current clipboard content")

                Menu {
                    directCaptureMenuItems
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                }
                .buttonStyle(.bordered)
                .disabled(isReadingClipboard || isLoadingDirectCapture)
                .accessibilityHint("Adds text or a photo instead of saving the clipboard")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(mode == .saveClipboard ? "clipboard-available" : "capture-bar")
    }

    @ViewBuilder
    private var directCaptureMenuItems: some View {
        Button(action: actions.newText) {
            Label("New Text", systemImage: "text.badge.plus")
        }
        Button(action: actions.choosePhoto) {
            Label("Choose Photo", systemImage: "photo.on.rectangle")
        }
        Button(action: actions.takePhoto) {
            Label("Take Photo", systemImage: "camera")
        }
    }
}

@available(iOS 26.0, *)
struct PocketTrayCaptureAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let mode: CaptureActionMode
    let isReadingClipboard: Bool
    let isLoadingDirectCapture: Bool
    let actions: CaptureBarActions

    var body: some View {
        PocketTrayCaptureBar(
            mode: mode,
            isReadingClipboard: isReadingClipboard,
            isLoadingDirectCapture: isLoadingDirectCapture,
            isCompact: placement == .inline,
            actions: actions
        )
        .padding(.horizontal, placement == .inline ? 4 : 12)
    }
}

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
