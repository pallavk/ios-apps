import SwiftUI
import UIKit

struct RootView: View {
    private enum SheetDestination: Identifiable {
        case createCollection
        case editItem(TrayItem)
        case previewImage(TrayItem)
        case previewPDF(TrayItem)
        case renameCollection(TrayCollection)

        var id: String {
            switch self {
            case .createCollection: "create-collection"
            case let .editItem(item): "edit-item-\(item.id)"
            case let .previewImage(item): "preview-image-\(item.id)"
            case let .previewPDF(item): "preview-pdf-\(item.id)"
            case let .renameCollection(collection): "rename-collection-\(collection.id)"
            }
        }
    }

    private enum Section: CaseIterable, Hashable {
        case recent
        case pinned
        case collections
        case trash

        var title: String {
            switch self {
            case .recent: "Recent"
            case .pinned: "Pinned"
            case .collections: "Collections"
            case .trash: "Trash"
            }
        }

        var systemImage: String {
            switch self {
            case .recent: "clock"
            case .pinned: "pin"
            case .collections: "folder"
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
    @State private var searchText = ""
    @State private var presentedSheet: SheetDestination?
    @State private var pendingCollectionDeletion: TrayCollection?
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
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .createCollection:
                CollectionEditor(title: "New Collection", initialName: "", tray: tray) {
                    await reload()
                }
            case let .editItem(item):
                ItemEditor(item: item, collections: snapshot.collections, tray: tray) {
                    await reload()
                }
            case let .previewImage(item):
                TrayImageDetailView(item: item, tray: tray)
            case let .previewPDF(item):
                TrayPDFDetailView(item: item, tray: tray)
            case let .renameCollection(collection):
                CollectionEditor(
                    title: "Rename Collection",
                    initialName: collection.name,
                    tray: tray,
                    collectionID: collection.id
                ) {
                    await reload()
                }
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
        .confirmationDialog(
            "Delete this collection?",
            isPresented: isConfirmingCollectionDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) {
                if let collection = pendingCollectionDeletion {
                    deleteCollection(collection)
                }
            }
            Button("Cancel", role: .cancel) { pendingCollectionDeletion = nil }
        } message: {
            Text("Objects in it will remain in Pocket Tray.")
        }
    }

    private func sectionNavigation(
        _ section: Section,
        items: [TrayItem]
    ) -> some View {
        NavigationStack {
            Group {
                if section == .recent {
                    sectionContent(section, items: items)
                        .searchable(text: $searchText, prompt: "Search Pocket Tray")
                } else {
                    sectionContent(section, items: items)
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
                if section == .collections {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { presentedSheet = .createCollection } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: Section, items: [TrayItem]) -> some View {
        if section == .collections {
            collectionsContent
        } else if section == .recent && !searchText.isEmpty && items.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if items.isEmpty {
            emptyState(for: section)
        } else {
            itemList(items, section: section)
        }
    }

    private func items(for section: Section) -> [TrayItem] {
        switch section {
        case .recent: snapshot.search(searchText)
        case .pinned: snapshot.pinned
        case .collections: []
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
                Text("Paste copied text or share an image or PDF to keep it here.")
            } actions: {
                saveClipboardButton.buttonBorderShape(.capsule)
            }
        case .pinned:
            ContentUnavailableView(
                "Nothing pinned",
                systemImage: "pin",
                description: Text("Pin an object to keep it from expiring.")
            )
        case .collections:
            EmptyView()
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

    @ViewBuilder
    private var collectionsContent: some View {
        if snapshot.collections.isEmpty {
            ContentUnavailableView {
                Label("No collections", systemImage: "folder")
            } description: {
                Text("Create a collection when you want a little more structure.")
            } actions: {
                Button("New Collection") { presentedSheet = .createCollection }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(snapshot.collections) { collection in
                    NavigationLink {
                        let collectionItems = snapshot.recent.filter {
                            $0.collectionID == collection.id
                        }
                        Group {
                            if collectionItems.isEmpty {
                                ContentUnavailableView(
                                    "Collection is empty",
                                    systemImage: "folder",
                                    description: Text("Edit an object to add it here.")
                                )
                            } else {
                                itemList(collectionItems, section: .collections)
                            }
                        }
                        .navigationTitle(collection.name)
                    } label: {
                        HStack {
                            Label(collection.name, systemImage: "folder")
                            Spacer()
                            Text(snapshot.recent.count { $0.collectionID == collection.id }, format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { presentedSheet = .renameCollection(collection) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingCollectionDeletion = collection } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
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
            if item.kind == .image {
                if section == .trash {
                    TrayImageRow(
                        item: item,
                        collectionName: collectionName(for: item),
                        tray: tray
                    )
                } else {
                    Button { presentedSheet = .previewImage(item) } label: {
                        TrayImageRow(
                            item: item,
                            collectionName: collectionName(for: item),
                            tray: tray
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityHint("Opens image preview and sharing")
                }
            } else if item.kind == .pdf {
                if section == .trash {
                    TrayPDFRow(
                        item: item,
                        collectionName: collectionName(for: item),
                        tray: tray
                    )
                } else {
                    Button { presentedSheet = .previewPDF(item) } label: {
                        TrayPDFRow(
                            item: item,
                            collectionName: collectionName(for: item),
                            tray: tray
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityHint("Opens PDF preview and sharing")
                }
            } else if section == .trash {
                TrayTextRow(item: item, collectionName: collectionName(for: item))
            } else {
                Button { copy(item) } label: {
                    TrayTextRow(item: item, collectionName: collectionName(for: item))
                }
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

            if section != .trash, let actions = item.analysis?.actions, !actions.isEmpty {
                Menu {
                    ForEach(actions) { action in
                        Button { perform(action) } label: {
                            Label(actionTitle(action), systemImage: actionSystemImage(action))
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Suggested actions")
                .accessibilityHint("Shows actions recognized in this object")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if section != .trash {
                Button { presentedSheet = .editItem(item) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
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

    private var isConfirmingCollectionDeletion: Binding<Bool> {
        Binding(
            get: { pendingCollectionDeletion != nil },
            set: { if !$0 { pendingCollectionDeletion = nil } }
        )
    }

    private func collectionName(for item: TrayItem) -> String? {
        guard let collectionID = item.collectionID else { return nil }
        return snapshot.collections.first { $0.id == collectionID }?.name
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

    private func deleteCollection(_ collection: TrayCollection) {
        pendingCollectionDeletion = nil
        perform("Collection deleted") {
            try await tray.deleteCollection(collection.id)
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

    private func perform(_ action: ContentAction) {
        if let target = action.target, let url = URL(string: target) {
            openURL(url)
            feedbackMessage = actionOpenedMessage(action)
        } else {
            perform("Copied \(actionCopyName(action))") {
                try await clipboard.copy(action.value)
            }
        }
    }

    private func actionTitle(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: "Open Link"
        case .phone: "Call \(action.value)"
        case .address: "Open in Maps"
        case .date: action.target == nil ? "Copy Date" : "Open Date"
        case .trackingNumber: action.target == nil ? "Copy Tracking Number" : "Track Package"
        }
    }

    private func actionSystemImage(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: "arrow.up.right.square"
        case .phone: "phone"
        case .address: "map"
        case .date: "calendar"
        case .trackingNumber: "shippingbox"
        }
    }

    private func actionOpenedMessage(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: "Opened link"
        case .phone: "Opened Phone"
        case .address: "Opened Maps"
        case .date: "Opened Calendar"
        case .trackingNumber: "Opened tracking"
        }
    }

    private func actionCopyName(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: "link"
        case .phone: "phone number"
        case .address: "address"
        case .date: "date"
        case .trackingNumber: "tracking number"
        }
    }

    private func reload() async {
        do {
            snapshot = try await tray.snapshot()
            await tray.waitForScheduledAnalysis()
            snapshot = try await tray.snapshot(rescheduleMissingAnalysis: false)
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
                    Text(item.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(item.text).foregroundStyle(.primary).lineLimit(4)
                }

                if let note = item.note {
                    Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }

                if let collectionName {
                    Label(collectionName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

private struct ItemEditor: View {
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
    }

    private func blankAsNil(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await tray.edit(
                item.id,
                text: text,
                title: blankAsNil(title),
                note: blankAsNil(note),
                collectionID: collectionID
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CollectionEditor: View {
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

#Preview("Empty tray") {
    RootView(tray: Tray(repository: InMemoryTrayRepository()))
}
