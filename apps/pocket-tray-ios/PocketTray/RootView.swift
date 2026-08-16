import SwiftUI
import UIKit

struct RootView: View {
    private struct Feedback: Identifiable {
        let id = UUID()
        let message: String
        let collectionItem: TrayItem?
    }

    private enum SheetDestination: Identifiable {
        case createCollection
        case assignCollection(TrayItem)
        case addItems(TrayCollection)
        case editItem(TrayItem)
        case previewImage(TrayItem)
        case previewPDF(TrayItem)
        case renameCollection(TrayCollection)
        case settings
        case systemCapture

        var id: String {
            switch self {
            case .createCollection: "create-collection"
            case let .assignCollection(item): "assign-collection-\(item.id)"
            case let .addItems(collection): "add-items-\(collection.id)"
            case let .editItem(item): "edit-item-\(item.id)"
            case let .previewImage(item): "preview-image-\(item.id)"
            case let .previewPDF(item): "preview-pdf-\(item.id)"
            case let .renameCollection(collection): "rename-collection-\(collection.id)"
            case .settings: "settings"
            case .systemCapture: "system-capture"
            }
        }
    }

    private enum Section: CaseIterable, Hashable {
        case recent
        case pinned
        case collections
        case trash
        case search

        static let primaryCases: [Section] = [.recent, .pinned, .collections, .trash]

        var title: String {
            switch self {
            case .recent: "Recent"
            case .pinned: "Pinned"
            case .collections: "Collections"
            case .trash: "Trash"
            case .search: "Search"
            }
        }

        var systemImage: String {
            switch self {
            case .recent: "clock"
            case .pinned: "pin"
            case .collections: "folder"
            case .trash: "trash"
            case .search: "magnifyingglass"
            }
        }
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let tray: Tray
    private let clipboard: any TextClipboard
    private let clipboardAvailabilityChecker: any ClipboardAvailabilityChecking
    private let clipboardContentReader: any ClipboardContentReading
    private let appLockController: AppLockController

    @State private var selectedSection = Section.recent
    @State private var snapshot = TraySnapshot.empty
    @State private var feedback: Feedback?
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var presentedSheet: SheetDestination?
    @State private var pendingCollectionDeletion: TrayCollection?
    @State private var pendingPermanentDeletion: TrayItem?
    @State private var pendingSensitiveCapture: PreparedTrayCapture?
    @State private var sensitivePreviewSession = SensitivePreviewSession()
    @State private var hasSupportedClipboardContent = false
    @State private var storageWarningMessage: String?
    @State private var hasShownStorageWarning = false
    @State private var isReadingClipboard = false

    init(
        tray: Tray,
        clipboard: any TextClipboard = SystemTextClipboard(),
        clipboardAvailabilityChecker: any ClipboardAvailabilityChecking = SystemClipboardAvailabilityChecker(),
        clipboardContentReader: any ClipboardContentReading = SystemClipboardContentReader(),
        appLockController: AppLockController = AppLockController()
    ) {
        self.tray = tray
        self.clipboard = clipboard
        self.clipboardAvailabilityChecker = clipboardAvailabilityChecker
        self.clipboardContentReader = clipboardContentReader
        self.appLockController = appLockController
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                TabView(selection: $selectedSection) {
                    ForEach(Section.primaryCases, id: \.self) { section in
                        Tab(section.title, systemImage: section.systemImage, value: section) {
                            sectionNavigation(section, items: items(for: section))
                        }
                    }
                    Tab(value: Section.search, role: .search) {
                        sectionNavigation(.search, items: items(for: .search))
                    }
                }
                .searchable(text: $searchText, prompt: "Search Pocket Tray")
            } else {
                TabView(selection: $selectedSection) {
                    ForEach(Section.allCases, id: \.self) { section in
                        sectionNavigation(section, items: items(for: section))
                            .tabItem { Label(section.title, systemImage: section.systemImage) }
                            .tag(section)
                    }
                }
            }
        }
        .task {
            await reload()
            await refreshStorageWarning()
            await refreshClipboardAvailability()
            presentControlCaptureIfRequested()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await reload()
                    await refreshStorageWarning()
                    await refreshClipboardAvailability()
                    presentControlCaptureIfRequested()
                }
            } else {
                sensitivePreviewSession.endForegroundSession()
            }
        }
        .overlay(alignment: .top) {
            if let feedback {
                FeedbackToast(
                    message: feedback.message,
                    actionTitle: feedback.collectionItem == nil ? nil : "Add to Collection"
                ) {
                    if let item = feedback.collectionItem {
                        presentedSheet = .assignCollection(item)
                    }
                    self.feedback = nil
                }
                .padding(.horizontal)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: feedback?.id)
        .task(id: feedback?.id) {
            guard let currentFeedback = feedback else { return }
            let feedbackID = currentFeedback.id
            let duration: Duration = currentFeedback.collectionItem == nil ? .seconds(2) : .seconds(5)
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, feedback?.id == feedbackID else { return }
            feedback = nil
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .createCollection:
                CollectionEditor(title: "New Collection", initialName: "", tray: tray) {
                    await reload()
                }
            case let .assignCollection(item):
                CollectionAssignmentView(
                    item: item,
                    collections: snapshot.collections,
                    tray: tray
                ) {
                    await reload()
                }
            case let .addItems(collection):
                CollectionItemPicker(
                    collection: collection,
                    items: snapshot.recent,
                    collections: snapshot.collections,
                    tray: tray
                ) {
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
            case .settings:
                AppLockSettingsView(controller: appLockController, tray: tray)
            case .systemCapture:
                ControlCapturePrompt { captureCurrentClipboard() }
            }
        }
        .alert("Pocket Tray couldn't complete that", isPresented: isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .alert("Pocket Tray storage is over 500 MB", isPresented: isShowingStorageWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storageWarningMessage ?? "Pocket Tray will keep your originals unchanged. Review usage in Settings.")
        }
        .confirmationDialog(
            "Save possible sensitive content?",
            isPresented: isConfirmingSensitiveCapture,
            titleVisibility: .visible
        ) {
            Button("Save Anyway") {
                if let prepared = pendingSensitiveCapture {
                    pendingSensitiveCapture = nil
                    commit(prepared, acknowledgingSensitiveContent: true)
                }
            }
            Button("Cancel", role: .cancel) { pendingSensitiveCapture = nil }
        } message: {
            Text(sensitiveCaptureWarning)
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
                if section == .search {
                    if #available(iOS 26.0, *) {
                        sectionContent(section, items: items)
                    } else {
                        sectionContent(section, items: items)
                            .searchable(text: $searchText, prompt: "Search Pocket Tray")
                    }
                } else {
                    sectionContent(section, items: items)
                }
            }
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { presentedSheet = .settings } label: {
                        Label("Settings", systemImage: "gearshape")
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
        if section == .recent, hasSupportedClipboardContent {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        clipboardReadyLabel
                        Spacer()
                        clipboardSaveButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        clipboardReadyLabel
                        clipboardSaveButton
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("clipboard-available")
                recentContent(items)
            }
        } else if section == .collections {
            collectionsContent
        } else if section == .search && !searchText.isEmpty && items.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if items.isEmpty {
            emptyState(for: section)
        } else {
            itemList(items, section: section)
        }
    }

    private var clipboardReadyLabel: some View {
        Label("Clipboard ready", systemImage: "clipboard")
            .font(.subheadline.weight(.medium))
    }

    private var clipboardSaveButton: some View {
        Button {
            captureCurrentClipboard()
        } label: {
            if isReadingClipboard {
                ProgressView().controlSize(.small)
            } else {
                Text("Save")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isReadingClipboard)
        .accessibilityHint("Reads and saves the current clipboard content")
    }

    @ViewBuilder
    private func recentContent(_ items: [TrayItem]) -> some View {
        if items.isEmpty {
            emptyState(for: .recent)
        } else {
            itemList(items, section: .recent)
        }
    }

    private func items(for section: Section) -> [TrayItem] {
        switch section {
        case .recent: snapshot.recent
        case .pinned: snapshot.pinned
        case .collections: []
        case .trash: snapshot.trash
        case .search: snapshot.search(searchText)
        }
    }

    @ViewBuilder
    private func emptyState(for section: Section) -> some View {
        switch section {
        case .recent:
            ContentUnavailableView {
                Label("Your tray is empty", systemImage: "tray")
            } description: {
                Text("Copy something in another app, or share text, an image, or a PDF to Pocket Tray.")
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
        case .search:
            ContentUnavailableView(
                "Nothing to search yet",
                systemImage: "magnifyingglass",
                description: Text("Saved objects will be searchable here.")
            )
        }
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
                                    description: Text("Use Add Items to place existing objects here.")
                                )
                            } else {
                                itemList(collectionItems, section: .collections)
                            }
                        }
                        .navigationTitle(collection.name)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { presentedSheet = .addItems(collection) } label: {
                                    Label("Add Items", systemImage: "plus")
                                }
                            }
                        }
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
            ForEach(items) { item in
                itemRow(item, section: section)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func itemRow(_ item: TrayItem, section: Section) -> some View {
        let isSensitiveHidden = !sensitivePreviewSession.allowsContentAccess(to: item)
        HStack(spacing: 12) {
            if isSensitiveHidden {
                SensitiveTrayRow(item: item)
            } else if item.kind == .image {
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

            }

            if item.protectsSensitivePreview, !isSensitiveHidden {
                Button {
                    sensitivePreviewSession.hide(item.id)
                } label: {
                    Image(systemName: "eye.slash")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide sensitive content")
            }

            itemOptionsMenu(item, section: section, isSensitiveHidden: isSensitiveHidden)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if section != .trash {
                if !isSensitiveHidden {
                    Button { presentedSheet = .editItem(item) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
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

    private func itemOptionsMenu(
        _ item: TrayItem,
        section: Section,
        isSensitiveHidden: Bool
    ) -> some View {
        Menu {
            if isSensitiveHidden {
                Button {
                    sensitivePreviewSession.reveal(item.id)
                } label: {
                    Label("Reveal", systemImage: "eye")
                }
                Button {
                    overrideSensitivity(item)
                } label: {
                    Label("Mark Not Sensitive", systemImage: "checkmark.shield")
                }
            }
            if section == .trash {
                Button { restore(item) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) { pendingPermanentDeletion = item } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
            } else {
                if !isSensitiveHidden {
                    switch item.kind {
                    case .image:
                        Button { presentedSheet = .previewImage(item) } label: {
                            Label("Preview and Share", systemImage: "photo")
                        }
                    case .pdf:
                        Button { presentedSheet = .previewPDF(item) } label: {
                            Label("Preview and Share", systemImage: "doc.richtext")
                        }
                    case .text:
                        Button { copy(item) } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }
                    case .url:
                        Button { copy(item) } label: {
                            Label("Copy Link", systemImage: "doc.on.doc")
                        }
                        Button { open(item) } label: {
                            Label("Open Link", systemImage: "arrow.up.right.square")
                        }
                    }
                    if let actions = item.analysis?.actions, !actions.isEmpty {
                        SwiftUI.Section("Suggested Actions") {
                            ForEach(actions) { action in
                                Button { perform(action) } label: {
                                    Label(
                                        action.suggestedTitle,
                                        systemImage: actionSystemImage(action)
                                    )
                                }
                            }
                        }
                    }
                }
                Button { presentedSheet = .assignCollection(item) } label: {
                    Label(
                        item.collectionID == nil ? "Add to Collection" : "Move or Remove Collection",
                        systemImage: "folder"
                    )
                }
                if !isSensitiveHidden {
                    Button { presentedSheet = .editItem(item) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                Button { setPinned(item, to: !item.isPinned) } label: {
                    Label(
                        item.isPinned ? "Unpin" : "Pin",
                        systemImage: item.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button(role: .destructive) { moveToTrash(item) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Object options")
        .accessibilityHint("Shows reuse, collection, edit, pin, and lifecycle actions")
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

    private var isConfirmingSensitiveCapture: Binding<Bool> {
        Binding(
            get: { pendingSensitiveCapture != nil },
            set: { if !$0 { pendingSensitiveCapture = nil } }
        )
    }

    private var sensitiveCaptureWarning: String {
        guard let reasons = pendingSensitiveCapture?.item.sensitivity?.reasons else {
            return "Pocket Tray found a possible secret."
        }
        let labels = SensitiveContentReason.ordered(reasons).map(\.warningLabel)
        return "Pocket Tray found a possible \(labels.joined(separator: " or ")). Save it only if you intend to keep it here."
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
        capture(.text(text))
    }

    private func capture(_ content: CaptureContent) {
        do {
            let prepared = try tray.prepareCapture(content)
            if prepared.item.protectsSensitivePreview {
                pendingSensitiveCapture = prepared
            } else {
                commit(prepared)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit(
        _ prepared: PreparedTrayCapture,
        acknowledgingSensitiveContent: Bool = false
    ) {
        Task {
            do {
                let saved = try await tray.commit(
                    prepared,
                    acknowledgingSensitiveContent: acknowledgingSensitiveContent
                )
                showFeedback(
                    "Saved to Pocket Tray",
                    collectionItem: snapshot.collections.isEmpty ? nil : saved
                )
                await reload()
                await refreshStorageWarning()
            } catch {
                errorMessage = error.localizedDescription
            }
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

    private func overrideSensitivity(_ item: TrayItem) {
        sensitivePreviewSession.hide(item.id)
        perform("Marked as not sensitive") {
            _ = try await tray.setSensitivityOverridden(item.id, to: true)
        }
    }

    private func perform(
        _ successMessage: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                showFeedback(successMessage)
                await reload()
                await refreshStorageWarning()
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
            openURL(url) { accepted in
                if accepted {
                    showFeedback(actionOpenedMessage(action))
                } else {
                    copyActionValue(action)
                }
            }
        } else {
            copyActionValue(action)
        }
    }

    private func copyActionValue(_ action: ContentAction) {
        perform("Copied \(actionCopyName(action))") {
            try await clipboard.copy(action.value)
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

    private func refreshClipboardAvailability() async {
        hasSupportedClipboardContent = await clipboardAvailabilityChecker.hasSupportedContent()
    }

    private var isShowingStorageWarning: Binding<Bool> {
        Binding(
            get: { storageWarningMessage != nil },
            set: { if !$0 { storageWarningMessage = nil } }
        )
    }

    private func refreshStorageWarning() async {
        guard !hasShownStorageWarning else { return }
        guard let report = try? await tray.storageReport(), report.exceedsWarningThreshold else {
            return
        }
        hasShownStorageWarning = true
        storageWarningMessage = "Pocket Tray is using \(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)). Nothing was deleted or compressed. Review usage in Settings."
    }

    private func presentControlCaptureIfRequested() {
        if ControlCaptureHandoff.consumeCaptureRequest() {
            presentedSheet = .systemCapture
        }
    }

    private func captureCurrentClipboard() {
        guard !isReadingClipboard else { return }
        isReadingClipboard = true
        Task {
            let content = await clipboardContentReader.readCurrentContent()
            isReadingClipboard = false
            presentedSheet = nil
            capture(content)
        }
    }

    private func showFeedback(
        _ message: String,
        collectionItem: TrayItem? = nil
    ) {
        feedback = Feedback(message: message, collectionItem: collectionItem)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private struct FeedbackToast: View {
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

private struct ControlCapturePrompt: View {
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

private struct SystemTextClipboard: TextClipboard {
    func copy(_ text: String) async {
        await MainActor.run { UIPasteboard.general.string = text }
    }
}

private struct SensitiveTrayRow: View {
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

private struct CollectionAssignmentView: View {
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

private struct CollectionItemPicker: View {
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

private extension TrayItemKind {
    var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .url: "link"
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
