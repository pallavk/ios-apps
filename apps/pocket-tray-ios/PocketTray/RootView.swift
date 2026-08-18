import PhotosUI
import SwiftUI
import UIKit

enum PocketTraySection: CaseIterable, Hashable {
    case recent
    case collections
    case search

    var title: String {
        switch self {
        case .recent: String(localized: "Recent")
        case .collections: String(localized: "Collections")
        case .search: String(localized: "Search")
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .collections: "folder"
        case .search: "magnifyingglass"
        }
    }
}

enum RecentFilter: CaseIterable, Hashable {
    case all
    case pinned

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .pinned: String(localized: "Pinned")
        }
    }

    func items(from recent: [TrayItem]) -> [TrayItem] {
        switch self {
        case .all: recent
        case .pinned: recent.filter(\.isPinned)
        }
    }
}

struct RootView: View {
    private enum UndoOperation {
        case restoreState(TrayItem)
        case renameCollection(UUID, String)
        case restoreCollectionOrder([UUID])
        case restoreDeletedCollection(DeletedCollection)
    }

    private enum FeedbackAction {
        case addToCollection(TrayItem)
        case undo(UndoOperation)
    }

    private struct Feedback: Identifiable {
        let id = UUID()
        let message: String
        let action: FeedbackAction?
    }

    private enum SheetDestination: Identifiable {
        case createCollection
        case detail(TrayItem)
        case assignCollection(TrayItem)
        case addItems(TrayCollection)
        case editItem(TrayItem)
        case newMedia(CaptureContent)
        case newText(UUID?)
        case previewImage(TrayItem)
        case previewPDF(TrayItem)
        case renameCollection(TrayCollection)
        case settings
        case systemCapture

        var id: String {
            switch self {
            case .createCollection: "create-collection"
            case let .detail(item): "detail-\(item.id)"
            case let .assignCollection(item): "assign-collection-\(item.id)"
            case let .addItems(collection): "add-items-\(collection.id)"
            case let .editItem(item): "edit-item-\(item.id)"
            case .newMedia: "new-media"
            case let .newText(collectionID): "new-text-\(collectionID?.uuidString ?? "none")"
            case let .previewImage(item): "preview-image-\(item.id)"
            case let .previewPDF(item): "preview-pdf-\(item.id)"
            case let .renameCollection(collection): "rename-collection-\(collection.id)"
            case .settings: "settings"
            case .systemCapture: "system-capture"
            }
        }
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(
        QuickCopyPreference.key,
        store: QuickCopyPreference.defaults
    ) private var quickCopyOnTap = false

    let tray: Tray
    private let clipboard: any TextClipboard
    private let clipboardAvailabilityChecker: any ClipboardAvailabilityChecking
    private let clipboardContentReader: any ClipboardContentReading
    private let appLockController: AppLockController

    @State private var selectedSection = PocketTraySection.recent
    @State private var recentFilter = RecentFilter.all
    @State private var snapshot = TraySnapshot.empty
    @State private var feedback: Feedback?
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var presentedSheet: SheetDestination?
    @State private var pendingPermanentDeletion: TrayItem?
    @State private var pendingSensitiveCapture: PreparedTrayCapture?
    @State private var pendingClipboardSaveChangeCount: Int?
    @State private var sensitivePreviewSession = SensitivePreviewSession()
    @State private var clipboardPromptState = ClipboardPromptState()
    @State private var storageWarningMessage: String?
    @State private var hasShownStorageWarning = false
    @State private var isReadingClipboard = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPresentingPhotoPicker = false
    @State private var isLoadingDirectCapture = false
    @State private var isPresentingCamera = false
    @State private var pendingCameraContent: CaptureContent?
    @State private var isShowingCameraPermissionHelp = false

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
                    Tab("Recent", systemImage: "clock", value: PocketTraySection.recent) {
                        sectionNavigation(.recent, items: items(for: .recent))
                    }
                    Tab("Collections", systemImage: "folder", value: PocketTraySection.collections) {
                        sectionNavigation(.collections, items: items(for: .collections))
                    }
                    Tab(value: PocketTraySection.search, role: .search) {
                        sectionNavigation(.search, items: items(for: .search))
                    }
                }
                .tabViewSearchActivation(.searchTabSelection)
                .searchable(text: $searchText, prompt: "Search Pocket Tray")
                .tabViewBottomAccessory {
                    PocketTrayCaptureAccessory(
                        mode: captureActionMode,
                        isReadingClipboard: isReadingClipboard,
                        isLoadingDirectCapture: isLoadingDirectCapture,
                        actions: captureBarActions
                    )
                }
            } else {
                TabView(selection: $selectedSection) {
                    ForEach(PocketTraySection.allCases, id: \.self) { section in
                        sectionNavigation(section, items: items(for: section))
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                bottomCaptureBar
                            }
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
            await presentSavedObjectIfRequested()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await reload()
                    await refreshStorageWarning()
                    await refreshClipboardAvailability()
                    presentControlCaptureIfRequested()
                    await presentSavedObjectIfRequested()
                }
            } else {
                sensitivePreviewSession.endForegroundSession()
            }
        }
        .onChange(of: selectedPhoto) { _, selection in
            guard let selection else { return }
            Task { await loadSelectedPhoto(selection) }
        }
        .photosPicker(
            isPresented: $isPresentingPhotoPicker,
            selection: $selectedPhoto,
            matching: .images,
            preferredItemEncoding: .current
        )
        .overlay(alignment: .top) {
            if let feedback {
                FeedbackToast(
                    message: feedback.message,
                    actionTitle: feedbackActionTitle(feedback.action)
                ) {
                    switch feedback.action {
                    case let .addToCollection(item):
                        presentedSheet = .assignCollection(item)
                    case let .undo(operation):
                        performUndo(operation)
                    case nil:
                        break
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
            let duration: Duration = currentFeedback.action == nil ? .seconds(2) : .seconds(5)
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, feedback?.id == feedbackID else { return }
            feedback = nil
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .createCollection:
                CollectionEditor(
                    title: String(localized: "New Collection"),
                    initialName: "",
                    tray: tray
                ) { _ in
                    await reload()
                }
            case let .detail(item):
                TrayObjectDetailView(
                    item: item,
                    collections: snapshot.collections,
                    tray: tray,
                    clipboard: clipboard
                ) { await reload() }
            case let .assignCollection(item):
                CollectionAssignmentView(
                    item: item,
                    collections: snapshot.collections,
                    tray: tray
                ) { updated in
                    showFeedback(
                        updated.collectionID == nil
                            ? String(localized: "Removed from Collection")
                            : String(localized: "Collection updated"),
                        action: .undo(.restoreState(item))
                    )
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
            case let .newMedia(content):
                DirectMediaComposer(
                    content: content,
                    service: DirectCaptureService(tray: tray),
                    collections: snapshot.collections
                ) { item in
                    await directCaptureDidSave(item)
                }
            case let .newText(collectionID):
                DirectTextComposer(
                    service: DirectCaptureService(tray: tray),
                    collections: snapshot.collections,
                    initialCollectionID: collectionID
                ) { item in
                    await directCaptureDidSave(item)
                }
            case let .previewImage(item):
                TrayImageDetailView(item: item, tray: tray)
            case let .previewPDF(item):
                TrayPDFDetailView(item: item, tray: tray)
            case let .renameCollection(collection):
                CollectionEditor(
                    title: String(localized: "Rename Collection"),
                    initialName: collection.name,
                    tray: tray,
                    collectionID: collection.id
                ) { _ in
                    showFeedback(
                        String(localized: "Collection renamed"),
                        action: .undo(.renameCollection(collection.id, collection.name))
                    )
                    await reload()
                }
            case .settings:
                PocketTraySettingsView(
                    controller: appLockController,
                    tray: tray,
                    trashCount: snapshot.trash.count
                ) {
                    trashContent
                }
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
        .alert("Camera Access Needed", isPresented: $isShowingCameraPermissionHelp) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            }
        } message: {
            Text("Allow camera access in Settings to take photos directly in Pocket Tray.")
        }
        .fullScreenCover(isPresented: $isPresentingCamera, onDismiss: presentPendingCameraContent) {
            CameraCaptureView { content in
                pendingCameraContent = content
                isPresentingCamera = false
            }
            .ignoresSafeArea()
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
            Button("Cancel", role: .cancel) {
                pendingSensitiveCapture = nil
                pendingClipboardSaveChangeCount = nil
            }
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
    }

    private func sectionNavigation(
        _ section: PocketTraySection,
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
                            Label("New Collection", systemImage: "folder.badge.plus")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomCaptureBar: some View {
        bottomCaptureControls
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
    }

    @ViewBuilder
    private var bottomCaptureControls: some View {
        PocketTrayCaptureBar(
            mode: captureActionMode,
            isReadingClipboard: isReadingClipboard,
            isLoadingDirectCapture: isLoadingDirectCapture,
            isCompact: false,
            actions: captureBarActions
        )
    }

    private var captureActionMode: CaptureActionMode {
        CaptureActionMode(clipboardPromptIsVisible: clipboardPromptState.isVisible)
    }

    private var captureBarActions: CaptureBarActions {
        CaptureBarActions(
            saveClipboard: captureCurrentClipboard,
            newText: { presentedSheet = .newText(nil) },
            choosePhoto: { isPresentingPhotoPicker = true },
            takePhoto: requestCameraCapture
        )
    }

    @ViewBuilder
    private func sectionContent(_ section: PocketTraySection, items: [TrayItem]) -> some View {
        if section == .recent {
            recentContent(items)
        } else if section == .collections {
            collectionsContent
        } else if section == .search && !searchText.isEmpty && items.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if items.isEmpty {
            emptyState(for: section)
        } else {
            itemList(items)
        }
    }

    @ViewBuilder
    private func recentContent(_ items: [TrayItem]) -> some View {
        VStack(spacing: 0) {
            Picker("Recent filter", selection: $recentFilter) {
                ForEach(RecentFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            if items.isEmpty {
                if recentFilter == .pinned {
                    ContentUnavailableView(
                        "Nothing pinned",
                        systemImage: "pin",
                        description: Text("Pin an object to keep it close and stop it expiring.")
                    )
                } else {
                    emptyState(for: .recent)
                }
            } else {
                itemList(items, groupsByCaptureDate: true)
            }
        }
    }

    private func items(for section: PocketTraySection) -> [TrayItem] {
        switch section {
        case .recent: recentFilter.items(from: snapshot.recent)
        case .collections: []
        case .search: snapshot.search(searchText)
        }
    }

    @ViewBuilder
    private func emptyState(for section: PocketTraySection) -> some View {
        switch section {
        case .recent:
            ContentUnavailableView {
                Label("Your tray is empty", systemImage: "tray")
            } description: {
                Text("Tap Add to save text or a photo, or copy and share something from another app.")
            }
        case .collections:
            EmptyView()
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
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14),
                    ],
                    spacing: 24
                ) {
                    ForEach(snapshot.collections) { collection in
                        ZStack(alignment: .topTrailing) {
                            NavigationLink {
                                collectionDetail(collection)
                            } label: {
                                CollectionCard(
                                    collection: collection,
                                    items: items(in: collection),
                                    tray: tray
                                )
                            }
                            .buttonStyle(.plain)

                            collectionOptions(collection)
                                .padding(8)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private func collectionDetail(_ collection: TrayCollection) -> some View {
        let collectionItems = items(in: collection)
        Group {
            if collectionItems.isEmpty {
                ContentUnavailableView {
                    Label("Collection is empty", systemImage: "folder")
                } description: {
                    Text("Add an existing object, or create new text here.")
                } actions: {
                    Button("Add Existing Objects") { presentedSheet = .addItems(collection) }
                        .buttonStyle(.borderedProminent)
                    Button("Add New Text") { presentedSheet = .newText(collection.id) }
                        .buttonStyle(.bordered)
                }
            } else {
                itemList(collectionItems)
            }
        }
        .navigationTitle(collection.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { presentedSheet = .addItems(collection) } label: {
                    Label("Add Existing Objects", systemImage: "plus")
                }
            }
        }
    }

    private func collectionOptions(_ collection: TrayCollection) -> some View {
        let index = snapshot.collections.firstIndex(where: { $0.id == collection.id }) ?? 0
        return Menu {
            Button { presentedSheet = .renameCollection(collection) } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { moveCollection(collection, by: -1) } label: {
                Label("Move Earlier", systemImage: "arrow.up")
            }
            .disabled(index == snapshot.collections.startIndex)
            Button { moveCollection(collection, by: 1) } label: {
                Label("Move Later", systemImage: "arrow.down")
            }
            .disabled(index == snapshot.collections.index(before: snapshot.collections.endIndex))
            Divider()
            Button(role: .destructive) { deleteCollection(collection) } label: {
                Label("Delete Collection", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Options for \(collection.name)")
    }

    private func items(in collection: TrayCollection) -> [TrayItem] {
        snapshot.recent.filter { $0.collectionID == collection.id }
    }

    @ViewBuilder
    private var trashContent: some View {
        Group {
            if snapshot.trash.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Deleted and expired objects remain here for seven days.")
                )
            } else {
                itemList(snapshot.trash, isTrash: true)
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func itemList(
        _ items: [TrayItem],
        isTrash: Bool = false,
        groupsByCaptureDate: Bool = false
    ) -> some View {
        TrayItemList(
            items: items,
            collections: snapshot.collections,
            tray: tray,
            isTrash: isTrash,
            groupsByCaptureDate: groupsByCaptureDate,
            quickCopyOnTap: quickCopyOnTap,
            sensitivePreviewSession: $sensitivePreviewSession,
            actions: TrayItemActions(
                showDetail: { presentedSheet = .detail($0) },
                previewImage: { presentedSheet = .previewImage($0) },
                previewPDF: { presentedSheet = .previewPDF($0) },
                copy: copy,
                open: open,
                assignCollection: { presentedSheet = .assignCollection($0) },
                edit: { presentedSheet = .editItem($0) },
                setPinned: setPinned,
                moveToTrash: moveToTrash,
                restore: restore,
                deletePermanently: { pendingPermanentDeletion = $0 },
                overrideSensitivity: overrideSensitivity,
                performSuggestedAction: perform
            )
        )
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
            return String(localized: "Pocket Tray found a possible secret.")
        }
        let labels = SensitiveContentReason.ordered(reasons).map(\.warningLabel)
        return String(localized: "Pocket Tray found possible sensitive content: \(labels.joined(separator: ", ")). Save it only if you intend to keep it here.")
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
            pendingClipboardSaveChangeCount = nil
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
                    String(localized: "Saved to Pocket Tray"),
                    action: snapshot.collections.isEmpty ? nil : .addToCollection(saved)
                )
                if pendingClipboardSaveChangeCount != nil {
                    clipboardPromptState.didSaveCurrentClipboard()
                    pendingClipboardSaveChangeCount = nil
                }
                await reload()
                await refreshStorageWarning()
                await refreshClipboardAvailability()
            } catch {
                pendingClipboardSaveChangeCount = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copy(_ item: TrayItem) {
        perform(String(localized: "Copied to clipboard")) {
            try await tray.reuse(item, using: clipboard)
        }
    }

    private func setPinned(_ item: TrayItem, to isPinned: Bool) {
        perform(
            isPinned ? String(localized: "Pinned") : String(localized: "Unpinned"),
            feedbackAction: .undo(.restoreState(item))
        ) {
            _ = try await tray.setPinned(item.id, to: isPinned)
        }
    }

    private func moveToTrash(_ item: TrayItem) {
        perform(
            String(localized: "Moved to Trash"),
            feedbackAction: .undo(.restoreState(item))
        ) {
            _ = try await tray.moveToTrash(item.id)
        }
    }

    private func restore(_ item: TrayItem) {
        perform(
            String(localized: "Restored to Recent"),
            feedbackAction: .undo(.restoreState(item))
        ) {
            _ = try await tray.restore(item.id)
        }
    }

    private func deletePermanently(_ item: TrayItem) {
        pendingPermanentDeletion = nil
        perform(String(localized: "Deleted permanently")) {
            try await tray.deletePermanently(item.id)
        }
    }

    private func deleteCollection(_ collection: TrayCollection) {
        Task {
            do {
                let deletion = try await tray.deleteCollectionForUndo(collection.id)
                showFeedback(
                    String(localized: "Collection deleted. Objects kept."),
                    action: .undo(.restoreDeletedCollection(deletion))
                )
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func moveCollection(_ collection: TrayCollection, by offset: Int) {
        let originalIDs = snapshot.collections.map(\.id)
        guard
            let source = snapshot.collections.firstIndex(where: { $0.id == collection.id }),
            snapshot.collections.indices.contains(source + offset)
        else { return }
        var reorderedIDs = originalIDs
        reorderedIDs.swapAt(source, source + offset)
        perform(
            String(localized: "Collection moved"),
            feedbackAction: .undo(.restoreCollectionOrder(originalIDs))
        ) {
            try await tray.reorderCollections(reorderedIDs)
        }
    }

    private func overrideSensitivity(_ item: TrayItem) {
        sensitivePreviewSession.hide(item.id)
        perform(String(localized: "Marked as not sensitive")) {
            _ = try await tray.setSensitivityOverridden(item.id, to: true)
        }
    }

    private func perform(
        _ successMessage: String,
        feedbackAction: FeedbackAction? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                showFeedback(successMessage, action: feedbackAction)
                await reload()
                await refreshStorageWarning()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performUndo(_ operation: UndoOperation) {
        perform(String(localized: "Undone")) {
            switch operation {
            case let .restoreState(original):
                _ = try await tray.restoreStateFromUndo(original)
            case let .renameCollection(id, name):
                _ = try await tray.renameCollection(id, to: name)
            case let .restoreCollectionOrder(ids):
                try await tray.reorderCollections(ids)
            case let .restoreDeletedCollection(deletion):
                try await tray.restoreDeletedCollection(deletion)
            }
        }
    }

    private func feedbackActionTitle(_ action: FeedbackAction?) -> String? {
        switch action {
        case .addToCollection: String(localized: "Add to Collection")
        case .undo: String(localized: "Undo")
        case nil: nil
        }
    }

    private func open(_ item: TrayItem) {
        guard let url = URL(string: item.text) else {
            errorMessage = String(localized: "Pocket Tray couldn't open that link.")
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
        perform(String(localized: "Copied \(actionCopyName(action))")) {
            try await clipboard.copy(action.value)
        }
    }

    private func actionOpenedMessage(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: String(localized: "Opened link")
        case .phone: String(localized: "Opened Phone")
        case .address: String(localized: "Opened Maps")
        case .date: String(localized: "Opened Calendar")
        case .trackingNumber: String(localized: "Opened tracking")
        }
    }

    private func actionCopyName(_ action: ContentAction) -> String {
        switch action.kind {
        case .url: String(localized: "link")
        case .phone: String(localized: "phone number")
        case .address: String(localized: "address")
        case .date: String(localized: "date")
        case .trackingNumber: String(localized: "tracking number")
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
        clipboardPromptState.observe(await clipboardAvailabilityChecker.currentSnapshot())
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
        storageWarningMessage = String(localized: "Pocket Tray is using \(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)). Nothing was deleted or compressed. Review usage in Settings.")
    }

    private func presentControlCaptureIfRequested() {
        if ControlCaptureHandoff.consumeCaptureRequest() {
            presentedSheet = .systemCapture
        }
    }

    private func presentSavedObjectIfRequested() async {
        guard let itemID = SavedObjectOpenHandoff.consumeOpenRequest() else { return }
        do {
            let item = try await SavedObjectShortcutService(
                tray: tray,
                clipboard: clipboard,
                isAppLockEnabled: { false }
            ).resolve(id: itemID)
            presentedSheet = .editItem(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func captureCurrentClipboard() {
        guard !isReadingClipboard else { return }
        isReadingClipboard = true
        pendingClipboardSaveChangeCount = clipboardPromptState.currentChangeCount
        Task {
            let content = await clipboardContentReader.readCurrentContent()
            isReadingClipboard = false
            presentedSheet = nil
            capture(content)
        }
    }

    private func loadSelectedPhoto(_ selection: PhotosPickerItem) async {
        isLoadingDirectCapture = true
        defer {
            isLoadingDirectCapture = false
            selectedPhoto = nil
        }
        do {
            let content = try await DirectPhotoLoader.load(selection)
            presentedSheet = .newMedia(content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestCameraCapture() {
        guard CameraAccess.isAvailable else {
            errorMessage = String(localized: "A camera isn't available on this device.")
            return
        }
        Task {
            if await CameraAccess.requestIfNeeded() {
                isPresentingCamera = true
            } else {
                isShowingCameraPermissionHelp = true
            }
        }
    }

    private func presentPendingCameraContent() {
        guard let content = pendingCameraContent else { return }
        pendingCameraContent = nil
        presentedSheet = .newMedia(content)
    }

    private func directCaptureDidSave(_ item: TrayItem) async {
        clipboardPromptState.dismissCurrentPrompt()
        showFeedback(
            String(localized: "Saved to Pocket Tray"),
            action: !snapshot.collections.isEmpty && item.collectionID == nil
                ? .addToCollection(item)
                : nil
        )
        await reload()
        await refreshStorageWarning()
    }

    private func showFeedback(
        _ message: String,
        action: FeedbackAction? = nil
    ) {
        feedback = Feedback(message: message, action: action)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

#Preview("Empty tray") {
    RootView(tray: Tray(repository: InMemoryTrayRepository()))
}
