import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let tray: Tray
    private let clipboard: any TextClipboard

    @State private var items: [TrayItem] = []
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?

    init(tray: Tray, clipboard: any TextClipboard = SystemTextClipboard()) {
        self.tray = tray
        self.clipboard = clipboard
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    recentList
                }
            }
            .navigationTitle("Recent")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    saveClipboardButton
                    .labelStyle(.titleAndIcon)
                    .accessibilityHint("Saves the current clipboard text to Pocket Tray")
                }
            }
        }
        .task {
            await reload()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await reload() }
            }
        }
        .alert("Pocket Tray couldn't save that", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your tray is empty", systemImage: "tray")
        } description: {
            Text("Copy some text, then tap Paste to keep it here.")
        } actions: {
            saveClipboardButton
            .buttonBorderShape(.capsule)
        }
    }

    private var saveClipboardButton: some View {
        PasteButton(payloadType: String.self) { strings in
            capture(strings.first)
        }
        .accessibilityLabel("Save clipboard text")
    }

    private var recentList: some View {
        List {
            if let feedbackMessage {
                Label(feedbackMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("capture-feedback")
            }

            ForEach(items) { item in
                HStack(spacing: 12) {
                    Button {
                        copy(item)
                    } label: {
                        TrayTextRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityHint("Copies this \(item.kind == .url ? "link" : "text")")

                    if item.kind == .url {
                        Button {
                            open(item)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open link")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func capture(_ text: String?) {
        guard let text else {
            errorMessage = TrayError.emptyText.localizedDescription
            return
        }

        Task {
            do {
                _ = try await tray.capture(.text(text))
                feedbackMessage = "Saved to Pocket Tray"
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copy(_ item: TrayItem) {
        Task {
            do {
                try await tray.reuse(item, using: clipboard)
                feedbackMessage = "Copied to clipboard"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func open(_ item: TrayItem) {
        guard let url = URL(string: item.text) else {
            errorMessage = "Pocket Tray couldn't open that link."
            return
        }
        openURL(url)
    }

    private func reload() async {
        do {
            items = try await tray.recent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SystemTextClipboard: TextClipboard {
    func copy(_ text: String) async {
        await MainActor.run {
            UIPasteboard.general.string = text
        }
    }
}

private struct TrayTextRow: View {
    let item: TrayItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .url ? "link" : "text.alignleft")
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                if item.kind == .url {
                    Text(URL(string: item.text)?.host() ?? "Link")
                        .font(.headline)
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(item.text)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                }

                Text(item.capturedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty tray") {
    RootView(tray: Tray(repository: InMemoryTrayRepository()))
}

#Preview("Recent text") {
    RootView(
        tray: Tray(
            repository: InMemoryTrayRepository(
                items: [
                    TrayItem(
                        id: UUID(),
                        text: "A useful piece of text that is ready to paste somewhere else.",
                        capturedAt: .now
                    )
                ]
            )
        )
    )
}
