import SwiftUI
import UIKit

struct CollectionAssignmentView: View {
    @Environment(\.dismiss) private var dismiss

    let item: TrayItem
    let collections: [TrayCollection]
    let tray: Tray
    let onSaved: () async -> Void

    @State private var collectionID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        item: TrayItem,
        collections: [TrayCollection],
        tray: Tray,
        onSaved: @escaping () async -> Void
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
                Section("Collection") {
                    Picker("Collection", selection: $collectionID) {
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
            _ = try await tray.assign(item.id, to: collectionID)
            await onSaved()
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
    @State private var updatingIDs: Set<UUID> = []
    @State private var errorMessage: String?

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
                                        item.collectionID != nil,
                                        item.collectionID != collection.id,
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
            .navigationTitle("Add Items")
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
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func collectionName(for item: TrayItem) -> String? {
        collections.first { $0.id == item.collectionID }?.name
    }

    private func toggle(_ item: TrayItem) {
        let shouldAdd = !selectedIDs.contains(item.id)
        updatingIDs.insert(item.id)
        Task {
            defer { updatingIDs.remove(item.id) }
            do {
                _ = try await tray.assign(item.id, to: shouldAdd ? collection.id : nil)
                if shouldAdd {
                    selectedIDs.insert(item.id)
                } else {
                    selectedIDs.remove(item.id)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
    let onSaved: () async -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        title: String,
        initialName: String,
        tray: Tray,
        collectionID: UUID? = nil,
        onSaved: @escaping () async -> Void
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
            if let collectionID {
                _ = try await tray.renameCollection(collectionID, to: name)
            } else {
                _ = try await tray.createCollection(named: name)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
