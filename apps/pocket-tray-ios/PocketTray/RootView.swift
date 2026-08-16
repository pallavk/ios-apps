import PhotosUI
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
        case newText
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
            case .newText: "new-text"
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
                    Tab("Recent", systemImage: "clock", value: Section.recent) {
                        sectionNavigation(.recent, items: items(for: .recent))
                    }
                    Tab("Pinned", systemImage: "pin", value: Section.pinned) {
                        sectionNavigation(.pinned, items: items(for: .pinned))
                    }
                    Tab("Collections", systemImage: "folder", value: Section.collections) {
                        sectionNavigation(.collections, items: items(for: .collections))
                    }
                    Tab("Trash", systemImage: "trash", value: Section.trash) {
                        sectionNavigation(.trash, items: items(for: .trash))
                    }
                    Tab(value: Section.search, role: .search) {
                        sectionNavigation(.search, items: items(for: .search))
                            .searchable(text: $searchText, prompt: "Search Pocket Tray")
                    }
                }
                .tabViewSearchActivation(.searchTabSelection)
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
            case .newText:
                DirectTextComposer(
                    service: DirectCaptureService(tray: tray),
                    collections: snapshot.collections
                ) { item in
                    await directCaptureDidSave(item)
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
        .alert("Camera Access Needed", isPresented: $isShowingCameraPermissionHelp) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            }
        } message: {
            Text("Allow camera access in Settings to take photos directly in Pocket Tray.")
        }
        .fullScreenCover(isPresented: $isPresentingCamera) {
            CameraCaptureView { content in
                isPresentingCamera = false
                guard let content else { return }
                Task { await saveDirectCaptureReportingErrors(content) }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            presentedSheet = .newText
                        } label: {
                            Label("New Text", systemImage: "text.badge.plus")
                        }
                        Button {
                            isPresentingPhotoPicker = true
                        } label: {
                            Label("Choose Photo", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            requestCameraCapture()
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    } label: {
                        if isLoadingDirectCapture {
                            ProgressView()
                        } else {
                            Label("Add", systemImage: "plus")
                        }
                    }
                    .disabled(isLoadingDirectCapture)
                    .accessibilityHint("Adds text or a photo directly to Pocket Tray")
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
    private func sectionContent(_ section: Section, items: [TrayItem]) -> some View {
        if section == .recent, clipboardPromptState.isVisible {
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
                Text("Tap Add to save text or a photo, or copy and share something from another app.")
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
        TrayItemList(
            items: items,
            collections: snapshot.collections,
            tray: tray,
            isTrash: section == .trash,
            sensitivePreviewSession: $sensitivePreviewSession,
            actions: TrayItemActions(
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
                    "Saved to Pocket Tray",
                    collectionItem: snapshot.collections.isEmpty ? nil : saved
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
        storageWarningMessage = "Pocket Tray is using \(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)). Nothing was deleted or compressed. Review usage in Settings."
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
            try await saveDirectCapture(content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestCameraCapture() {
        guard CameraAccess.isAvailable else {
            errorMessage = "A camera isn't available on this device."
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

    private func saveDirectCapture(_ content: CaptureContent) async throws {
        if let item = try await DirectCaptureService(tray: tray).capture(content) {
            await directCaptureDidSave(item)
        }
    }

    private func saveDirectCaptureReportingErrors(_ content: CaptureContent) async {
        do {
            try await saveDirectCapture(content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func directCaptureDidSave(_ item: TrayItem) async {
        clipboardPromptState.dismissCurrentPrompt()
        showFeedback(
            "Saved to Pocket Tray",
            collectionItem: !snapshot.collections.isEmpty && item.collectionID == nil ? item : nil
        )
        await reload()
        await refreshStorageWarning()
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

#Preview("Empty tray") {
    RootView(tray: Tray(repository: InMemoryTrayRepository()))
}
