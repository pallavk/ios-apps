import SwiftUI
import UIKit

enum CollectionCoverFallback: Equatable {
    case empty
    case sensitive
}

struct CollectionCoverContent: Equatable {
    let tiles: [TrayItem]
    let fallback: CollectionCoverFallback?

    init(items: [TrayItem]) {
        tiles = Array(items.filter { !$0.protectsSensitivePreview }.prefix(4))
        if !tiles.isEmpty {
            fallback = nil
        } else if items.contains(where: \.protectsSensitivePreview) {
            fallback = .sensitive
        } else {
            fallback = .empty
        }
    }
}

struct CollectionCard: View {
    let collection: TrayCollection
    let items: [TrayItem]
    let tray: Tray

    private var cover: CollectionCoverContent { CollectionCoverContent(items: items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            coverView
                .aspectRatio(1.35, contentMode: .fit)

            Text(collection.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(items.count) \(items.count == 1 ? "object" : "objects")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collection.name), \(items.count) \(items.count == 1 ? "object" : "objects")")
        .accessibilityHint("Opens this collection")
    }

    @ViewBuilder
    private var coverView: some View {
        if cover.tiles.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                VStack(spacing: 8) {
                    Image(systemName: cover.fallback == .sensitive ? "eye.slash" : "tray")
                        .font(.title2)
                    Text(cover.fallback == .sensitive ? "Contents hidden" : "Ready for objects")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
                spacing: 4
            ) {
                ForEach(cover.tiles) { item in
                    CollectionCoverTile(item: item, tray: tray)
                }
            }
            .padding(4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct CollectionCoverTile: View {
    let item: TrayItem
    let tray: Tray

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                VStack(spacing: 5) {
                    Image(systemName: item.kind.systemImage)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if item.kind == .text || item.kind == .url {
                    Text(item.title ?? item.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: item.asset?.digest) {
            guard item.kind == .image else { return }
            image = try? await TrayImageLoader.thumbnail(
                for: item,
                tray: tray,
                maxPixelSize: 320
            ).image
        }
    }
}

struct CollectionAssignmentView: View {
    @Environment(\.dismiss) private var dismiss

    let item: TrayItem
    let collections: [TrayCollection]
    let tray: Tray
    let onSaved: (TrayItem) async -> Void

    @State private var collectionID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        item: TrayItem,
        collections: [TrayCollection],
        tray: Tray,
        onSaved: @escaping (TrayItem) async -> Void
    ) {
        self.item = item
        self.collections = collections
        self.tray = tray
        self.onSaved = onSaved
        _collectionID = State(initialValue: item.collectionID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Object") {
                    Text(item.title ?? item.text)
                        .lineLimit(3)
                }
                Section("Save to Collection") {
                    Picker("Save to Collection", selection: $collectionID) {
                        Text("None").tag(UUID?.none)
                        ForEach(collections) { collection in
                            Text(collection.name).tag(Optional(collection.id))
                        }
                    }
                    .pickerStyle(.inline)
                    if collections.isEmpty {
                        Text("Create a collection from the Collections tab, then return here to assign this object.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(item.collectionID == nil ? "Add to Collection" : "Move Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving || collectionID == item.collectionID)
                }
            }
        }
        .alert("Couldn't update the collection", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await tray.assign(item.id, to: collectionID)
            await onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
struct CollectionItemPicker: View {
    @Environment(\.dismiss) private var dismiss

    let collection: TrayCollection
    let items: [TrayItem]
    let collections: [TrayCollection]
    let tray: Tray
    let onChanged: () async -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var currentItems: [UUID: TrayItem]
    @State private var updatingIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var undoItem: TrayItem?
    @State private var feedbackMessage: String?
    @State private var feedbackID: UUID?

    init(
        collection: TrayCollection,
        items: [TrayItem],
        collections: [TrayCollection],
        tray: Tray,
        onChanged: @escaping () async -> Void
    ) {
        self.collection = collection
        self.items = items
        self.collections = collections
        self.tray = tray
        self.onChanged = onChanged
        _selectedIDs = State(
            initialValue: Set(items.filter { $0.collectionID == collection.id }.map(\.id))
        )
        _currentItems = State(
            initialValue: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No objects available",
                        systemImage: "tray",
                        description: Text("Save an object before adding it to this collection.")
                    )
                } else {
                    List(items) { item in
                        Button { toggle(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title ?? item.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    if
                                        currentItems[item.id]?.collectionID != nil,
                                        currentItems[item.id]?.collectionID != collection.id,
                                        let currentName = collectionName(for: item)
                                    {
                                        Text("Currently in \(currentName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if updatingIDs.contains(item.id) {
                                    ProgressView().controlSize(.small)
                                } else if selectedIDs.contains(item.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(updatingIDs.contains(item.id))
                        .accessibilityLabel(item.title ?? item.text)
                        .accessibilityValue(selectedIDs.contains(item.id) ? "In collection" : "Not in collection")
                        .accessibilityHint(
                            selectedIDs.contains(item.id)
                                ? "Removes this object from the collection"
                                : "Adds this object to the collection"
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Existing Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Couldn't update that object", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .overlay(alignment: .top) {
            if let feedbackMessage, undoItem != nil {
                FeedbackToast(message: feedbackMessage, actionTitle: "Undo") {
                    undoLastChange()
                }
                .padding(.horizontal)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: feedbackMessage)
        .task(id: feedbackID) {
            guard let id = feedbackID else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, feedbackID == id else { return }
            undoItem = nil
            feedbackMessage = nil
            feedbackID = nil
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func collectionName(for item: TrayItem) -> String? {
        collections.first { $0.id == currentItems[item.id]?.collectionID }?.name
    }

    private func toggle(_ item: TrayItem) {
        let original = currentItems[item.id] ?? item
        let shouldAdd = original.collectionID != collection.id
        updatingIDs.insert(item.id)
        Task {
            defer { updatingIDs.remove(item.id) }
            do {
                let updated = try await tray.assign(item.id, to: shouldAdd ? collection.id : nil)
                currentItems[item.id] = updated
                if shouldAdd {
                    selectedIDs.insert(item.id)
                } else {
                    selectedIDs.remove(item.id)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                undoItem = original
                feedbackMessage = shouldAdd ? "Added to Collection" : "Removed from Collection"
                feedbackID = UUID()
                await onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func undoLastChange() {
        guard let original = undoItem else { return }
        undoItem = nil
        feedbackMessage = nil
        feedbackID = nil
        updatingIDs.insert(original.id)
        Task {
            defer { updatingIDs.remove(original.id) }
            do {
                let restored = try await tray.restoreStateFromUndo(original)
                currentItems[original.id] = restored
                if original.collectionID == collection.id {
                    selectedIDs.insert(original.id)
                } else {
                    selectedIDs.remove(original.id)
                }
                await onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension TrayItemKind {
    var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .url: "link"
        }
    }
}

struct CollectionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let tray: Tray
    let collectionID: UUID?
    let onSaved: (TrayCollection) async -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        title: String,
        initialName: String,
        tray: Tray,
        collectionID: UUID? = nil,
        onSaved: @escaping (TrayCollection) async -> Void
    ) {
        self.title = title
        self.tray = tray
        self.collectionID = collectionID
        self.onSaved = onSaved
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection name", text: $name)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(
                            isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .presentationDetents([.medium])
        .alert("Couldn't save that collection", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: TrayCollection
            if let collectionID {
                saved = try await tray.renameCollection(collectionID, to: name)
            } else {
                saved = try await tray.createCollection(named: name)
            }
            await onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
