import SwiftUI
import UIKit

struct RootView: View {
    private enum Section: CaseIterable, Hashable {
        case recent
        case pinned
        case trash

        var title: String {
            switch self {
            case .recent: "Recent"
            case .pinned: "Pinned"
            case .trash: "Trash"
            }
        }

        var systemImage: String {
            switch self {
            case .recent: "clock"
            case .pinned: "pin"
            case .trash: "trash"
            }
        }
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let tray: Tray
    private let clipboard: any TextClipboard

    @State private var selectedSection = Section.recent
    @State private var snapshot = TraySnapshot.empty
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?
    @State private var pendingPermanentDeletion: TrayItem?

    init(tray: Tray, clipboard: any TextClipboard = SystemTextClipboard()) {
        self.tray = tray
        self.clipboard = clipboard
    }

    var body: some View {
        TabView(selection: $selectedSection) {
            ForEach(Section.allCases, id: \.self) { section in
                sectionNavigation(section, items: items(for: section))
                    .tabItem { Label(section.title, systemImage: section.systemImage) }
                    .tag(section)
            }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await reload() }
            }
        }
        .alert("Pocket Tray couldn't complete that", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .confirmationDialog(
            "Delete this object permanently?",
            isPresented: isConfirmingPermanentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let item = pendingPermanentDeletion {
                    deletePermanently(item)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDeletion = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func sectionNavigation(
        _ section: Section,
        items: [TrayItem]
    ) -> some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState(for: section)
                } else {
                    itemList(items, section: section)
                }
            }
            .navigationTitle(section.title)
            .toolbar {
                if section == .recent {
                    ToolbarItem(placement: .topBarTrailing) {
                        saveClipboardButton
                            .labelStyle(.titleAndIcon)
                            .accessibilityHint("Saves the current clipboard text to Pocket Tray")
                    }
                }
            }
        }
    }

    private func items(for section: Section) -> [TrayItem] {
        switch section {
        case .recent: snapshot.recent
        case .pinned: snapshot.pinned
        case .trash: snapshot.trash
        }
    }

    @ViewBuilder
    private func emptyState(for section: Section) -> some View {
        switch section {
        case .recent:
            ContentUnavailableView {
                Label("Your tray is empty", systemImage: "tray")
            } description: {
                Text("Copy some text, then tap Paste to keep it here.")
            } actions: {
                saveClipboardButton.buttonBorderShape(.capsule)
            }
        case .pinned:
            ContentUnavailableView(
                "Nothing pinned",
                systemImage: "pin",
                description: Text("Pin an object to keep it from expiring.")
            )
        case .trash:
            ContentUnavailableView(
                "Trash is empty",
                systemImage: "trash",
                description: Text("Deleted and expired objects remain here for seven days.")
            )
        }
    }

    private var saveClipboardButton: some View {
        PasteButton(payloadType: String.self) { strings in
            capture(strings.first)
        }
        .accessibilityLabel("Save clipboard text")
    }

    private func itemList(_ items: [TrayItem], section: Section) -> some View {
        List {
            if let feedbackMessage {
                Label(feedbackMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("action-feedback")
            }

            ForEach(items) { item in
                itemRow(item, section: section)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func itemRow(_ item: TrayItem, section: Section) -> some View {
        HStack(spacing: 12) {
            if section == .trash {
                TrayTextRow(item: item)
            } else {
                Button { copy(item) } label: { TrayTextRow(item: item) }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityHint("Copies this \(item.kind == .url ? "link" : "text")")

                if item.kind == .url {
                    Button { open(item) } label: {
                        Image(systemName: "arrow.up.right.square").imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open link")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if section != .trash {
                Button { setPinned(item, to: !item.isPinned) } label: {
                    Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: section != .trash) {
            if section == .trash {
                Button { restore(item) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
                Button(role: .destructive) { pendingPermanentDeletion = item } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
            } else {
                Button(role: .destructive) { moveToTrash(item) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var isConfirmingPermanentDeletion: Binding<Bool> {
        Binding(
            get: { pendingPermanentDeletion != nil },
            set: { if !$0 { pendingPermanentDeletion = nil } }
        )
    }

    private func capture(_ text: String?) {
        guard let text else {
            errorMessage = TrayError.emptyText.localizedDescription
            return
        }
        perform("Saved to Pocket Tray") {
            _ = try await tray.capture(.text(text))
        }
    }

    private func copy(_ item: TrayItem) {
        perform("Copied to clipboard") {
            try await tray.reuse(item, using: clipboard)
        }
    }

    private func setPinned(_ item: TrayItem, to isPinned: Bool) {
        perform(isPinned ? "Pinned" : "Unpinned") {
            _ = try await tray.setPinned(item.id, to: isPinned)
        }
    }

    private func moveToTrash(_ item: TrayItem) {
        perform("Moved to Trash") {
            _ = try await tray.moveToTrash(item.id)
        }
    }

    private func restore(_ item: TrayItem) {
        perform("Restored to Recent") {
            _ = try await tray.restore(item.id)
        }
    }

    private func deletePermanently(_ item: TrayItem) {
        pendingPermanentDeletion = nil
        perform("Deleted permanently") {
            try await tray.deletePermanently(item.id)
        }
    }

    private func perform(
        _ successMessage: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                feedbackMessage = successMessage
                await reload()
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
            snapshot = try await tray.snapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SystemTextClipboard: TextClipboard {
    func copy(_ text: String) async {
        await MainActor.run { UIPasteboard.general.string = text }
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
                    Text(URL(string: item.text)?.host() ?? "Link").font(.headline)
                    Text(item.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(item.text).foregroundStyle(.primary).lineLimit(4)
                }

                lifecycleLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var lifecycleLabel: some View {
        if let trashedAt = item.trashedAt {
            Text("Deleted \(trashedAt, format: .relative(presentation: .named))")
        } else if item.isPinned {
            Text("Does not expire")
        } else if let expiresAt = item.expiresAt {
            Text("Expires \(expiresAt, format: .relative(presentation: .named))")
        } else {
            Text(item.capturedAt, format: .relative(presentation: .named))
        }
    }
}

#Preview("Empty tray") {
    RootView(tray: Tray(repository: InMemoryTrayRepository()))
}
