import SwiftUI

struct ItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    let item: TrayItem
    let collections: [TrayCollection]
    let tray: Tray
    let onSaved: () async -> Void

    @State private var text: String
    @State private var title: String
    @State private var note: String
    @State private var collectionID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isConfirmingSensitiveEdit = false

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
        _text = State(initialValue: item.text)
        _title = State(initialValue: item.title ?? "")
        _note = State(initialValue: item.note ?? "")
        _collectionID = State(initialValue: item.collectionID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if item.asset == nil {
                    Section("Content") {
                        TextEditor(text: $text)
                            .frame(minHeight: 120)
                            .accessibilityLabel("Object text")
                    }
                }
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Collection", selection: $collectionID) {
                        Text("None").tag(UUID?.none)
                        ForEach(collections) { collection in
                            Text(collection.name).tag(Optional(collection.id))
                        }
                    }
                }
            }
            .navigationTitle("Edit Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(
                            isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .alert("Couldn't update that object", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .confirmationDialog(
            "Save possible sensitive content?",
            isPresented: $isConfirmingSensitiveEdit,
            titleVisibility: .visible
        ) {
            Button("Save Anyway") { Task { await save(acknowledgingSensitiveContent: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pocket Tray found a possible secret. Save it only if you intend to keep it here.")
        }
    }

    private func blankAsNil(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save(acknowledgingSensitiveContent: Bool = false) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await tray.edit(
                item.id,
                text: text,
                title: blankAsNil(title),
                note: blankAsNil(note),
                collectionID: collectionID,
                acknowledgingSensitiveContent: acknowledgingSensitiveContent
            )
            await onSaved()
            dismiss()
        } catch TrayError.sensitiveContentRequiresAcknowledgment(_) {
            isConfirmingSensitiveEdit = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
