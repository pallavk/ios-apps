import SwiftUI
import UIKit

struct TrayObjectDetailView: View {
    let collections: [TrayCollection]
    let tray: Tray
    let clipboard: any TextClipboard
    let onChanged: () async -> Void

    @State private var item: TrayItem
    @State private var isAssigningCollection = false
    @State private var undoItem: TrayItem?
    @State private var feedbackMessage: String?
    @State private var feedbackID: UUID?
    @State private var errorMessage: String?

    init(
        item: TrayItem,
        collections: [TrayCollection],
        tray: Tray,
        clipboard: any TextClipboard,
        onChanged: @escaping () async -> Void
    ) {
        self.collections = collections
        self.tray = tray
        self.clipboard = clipboard
        self.onChanged = onChanged
        _item = State(initialValue: item)
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch item.kind {
            case .text, .url:
                TrayTextDetailView(
                    item: item,
                    collectionName: collectionName,
                    clipboard: clipboard,
                    manageCollection: { isAssigningCollection = true }
                )
            case .image:
                TrayImageDetailView(
                    item: item,
                    collectionName: collectionName,
                    tray: tray,
                    manageCollection: { isAssigningCollection = true }
                )
            case .pdf:
                TrayPDFDetailView(
                    item: item,
                    collectionName: collectionName,
                    tray: tray,
                    manageCollection: { isAssigningCollection = true }
                )
            }
        }
        .sheet(isPresented: $isAssigningCollection) {
            CollectionAssignmentView(item: item, collections: collections, tray: tray) { updated in
                undoItem = item
                item = updated
                feedbackMessage = updated.collectionID == nil
                    ? "Removed from Collection"
                    : "Collection updated"
                feedbackID = UUID()
                await onChanged()
            }
        }
        .overlay(alignment: .top) {
            if let feedbackMessage, undoItem != nil {
                FeedbackToast(message: feedbackMessage, actionTitle: "Undo") {
                    undoCollectionChange()
                }
                .padding(.horizontal)
                .safeAreaPadding(.top, 8)
            }
        }
        .task(id: feedbackID) {
            guard let id = feedbackID else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, feedbackID == id else { return }
            undoItem = nil
            feedbackMessage = nil
            feedbackID = nil
        }
        .alert("Couldn't undo that change", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var collectionName: String? {
        guard let collectionID = item.collectionID else { return nil }
        return collections.first { $0.id == collectionID }?.name
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func undoCollectionChange() {
        guard let original = undoItem else { return }
        Task {
            do {
                item = try await tray.restoreStateFromUndo(original)
                undoItem = nil
                feedbackMessage = nil
                feedbackID = nil
                await onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TrayTextDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let item: TrayItem
    let collectionName: String?
    let clipboard: any TextClipboard
    let manageCollection: () -> Void

    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            detailContent
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if item.kind == .url {
                    ToolbarItem(placement: .primaryAction) {
                        Button { copy() } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryAction
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .alert("Pocket Tray couldn't reuse that", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var navigationTitle: String {
        item.title ?? (item.kind == .url ? String(localized: "Link") : String(localized: "Text"))
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                contentTypeLabel

                if let title = item.title {
                    Text(title)
                        .font(.title2.weight(.semibold))
                }

                contentText

                if let note = item.note {
                    Text(note)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Divider()
                TrayDetailMetadata(
                    item: item,
                    collectionName: collectionName,
                    manageCollection: manageCollection
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var contentTypeLabel: some View {
        Label(
            item.kind == .url ? "Link" : "Text",
            systemImage: item.kind == .url ? "link" : "text.alignleft"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var contentText: some View {
        if item.kind == .url {
            Text(item.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(item.text)
                .font(.title3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryAction: some View {
        Button {
            if item.kind == .url {
                openLink()
            } else {
                copy()
            }
        } label: {
            Label(
                copied ? "Copied" : (item.kind == .url ? "Open Link" : "Copy Text"),
                systemImage: copied
                    ? "checkmark"
                    : (item.kind == .url ? "arrow.up.right.square" : "doc.on.doc")
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("detail-primary-action")
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func openLink() {
        guard let url = URL(string: item.text) else {
            errorMessage = String(localized: "Pocket Tray couldn't open that link.")
            return
        }
        openURL(url) { accepted in
            if !accepted {
                errorMessage = String(localized: "No app could open that link.")
            }
        }
    }

    private func copy() {
        Task {
            do {
                try await clipboard.copy(item.text)
                copied = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: "Copied")
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TrayDetailMetadata: View {
    let item: TrayItem
    let collectionName: String?
    var manageCollection: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let collectionName {
                Label(collectionName, systemImage: "folder")
            }
            if let manageCollection {
                Button(action: manageCollection) {
                    Label(
                        collectionName == nil ? "Add to Collection" : "Move or Remove Collection",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            TraySensitivityMetadata(item: item)
            if item.isPinned {
                Label("Pinned · Does not expire", systemImage: "pin.fill")
            } else if let expiresAt = item.expiresAt {
                Label(
                    "Expires \(expiresAt, format: .relative(presentation: .named))",
                    systemImage: "clock"
                )
            }
            Label(
                "Saved \(item.capturedAt, format: .relative(presentation: .named))",
                systemImage: "calendar"
            )
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

struct TraySensitivityMetadata: View {
    let item: TrayItem

    @ViewBuilder
    var body: some View {
        if item.protectsSensitivePreview {
            Label("Sensitive", systemImage: "exclamationmark.shield")
        }
    }
}

struct SensitiveTrayRow: View {
    let item: TrayItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sensitive content hidden")
                    .font(.headline)
                Text(reasonDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Use the options button to reveal or correct this warning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sensitive-content-cover")
        .accessibilityLabel(
            "\(kindName) object. Sensitive content hidden. \(reasonDescription) Use Object options to reveal or correct this warning."
        )
    }

    private var reasonDescription: String {
        let labels = item.sensitivity.map {
            SensitiveContentReason.ordered($0.reasons).map(\.warningLabel)
        } ?? []
        guard !labels.isEmpty else { return "Pocket Tray found a possible secret." }
        return "Possible \(labels.joined(separator: " or "))."
    }

    private var kindName: String {
        switch item.kind {
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .url: "Link"
        }
    }
}

struct TrayTextRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: TrayItem
    let collectionName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .url ? "link" : "text.alignleft")
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                if let title = item.title {
                    Text(title).font(.headline)
                }
                if item.kind == .url {
                    if item.title == nil {
                        Text(URL(string: item.text)?.host() ?? "Link").font(.headline)
                    }
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                } else {
                    Text(item.text)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                }

                if let note = item.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }

                if let collectionName {
                    Label(collectionName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TraySensitivityMetadata(item: item)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        .accessibilityLabel(accessibilitySummary)
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

    private var accessibilitySummary: String {
        var parts = [item.kind == .url ? "Link" : "Text"]
        if let title = item.title { parts.append(title) }
        parts.append(item.text)
        if let note = item.note { parts.append("Note \(note)") }
        if let collectionName { parts.append("Collection \(collectionName)") }
        if item.protectsSensitivePreview { parts.append("Sensitive") }
        if let trashedAt = item.trashedAt {
            parts.append("Deleted \(trashedAt.formatted(.relative(presentation: .named)))")
        } else if item.isPinned {
            parts.append("Pinned, does not expire")
        } else if let expiresAt = item.expiresAt {
            parts.append("Expires \(expiresAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ". ")
    }
}
