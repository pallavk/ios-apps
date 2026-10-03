import AppIntents
@preconcurrency import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum SpotlightDiscoveryPreference {
    static let key = "spotlightDiscovery.isEnabled"
    static let reconciliationPendingKey = "spotlightDiscovery.reconciliationPending"
    @MainActor
    static let defaults = UserDefaults(
        suiteName: FileTrayRepository.appGroupIdentifier
    ) ?? .standard
}

enum SavedObjectShortcutError: Error, Equatable, LocalizedError {
    case appLockEnabled
    case incompatibleContent
    case itemUnavailable

    var errorDescription: String? {
        switch self {
        case .appLockEnabled:
            String(localized: "Pocket Tray is locked. Open the app and authenticate before reusing saved objects.")
        case .incompatibleContent:
            String(localized: "That saved object does not provide the content type this action needs.")
        case .itemUnavailable:
            String(localized: "That Pocket Tray object is no longer available. Choose another saved object.")
        }
    }
}

struct SavedObjectShortcutService: Sendable {
    let tray: Tray
    let clipboard: any TextClipboard
    let isAppLockEnabled: @Sendable () async -> Bool

    func discoverableItems() async throws -> [TrayItem] {
        guard !(await isAppLockEnabled()) else {
            throw SavedObjectShortcutError.appLockEnabled
        }
        return try await tray.recent()
            .filter { !$0.protectsSensitivePreview }
            .sorted { left, right in
                if left.isPinned != right.isPinned { return left.isPinned }
                return left.capturedAt > right.capturedAt
            }
    }

    func resolve(id: UUID) async throws -> TrayItem {
        guard let item = try await discoverableItems().first(where: { $0.id == id }) else {
            throw SavedObjectShortcutError.itemUnavailable
        }
        return item
    }

    func find(_ query: String) async throws -> [TrayItem] {
        let available = try await discoverableItems()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return available }
        return available.filter { item in
            [item.title, item.text, item.note]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func copy(id: UUID) async throws -> TrayItem {
        let item = try await resolve(id: id)
        guard item.kind == .text || item.kind == .url else {
            throw SavedObjectShortcutError.incompatibleContent
        }
        try await tray.reuse(item, using: clipboard)
        return item
    }

    func text(id: UUID) async throws -> String {
        let item = try await resolve(id: id)
        guard item.kind == .text else {
            throw SavedObjectShortcutError.incompatibleContent
        }
        return item.text
    }

    func url(id: UUID) async throws -> URL {
        let item = try await resolve(id: id)
        guard item.kind == .url, let url = URL(string: item.text) else {
            throw SavedObjectShortcutError.incompatibleContent
        }
        return url
    }

    func file(id: UUID) async throws -> TrayAssetResource {
        let item = try await resolve(id: id)
        guard item.kind == .image || item.kind == .pdf else {
            throw SavedObjectShortcutError.incompatibleContent
        }
        return try await tray.assetResource(for: item)
    }

    func entities(withKinds kinds: [TrayItemKind]) async throws -> [SavedObjectEntity] {
        try await discoverableItems()
            .filter { kinds.contains($0.kind) }
            .map(SavedObjectEntity.init)
    }

    static func live() throws -> Self {
        let repository = try FileTrayRepository.sharedContainer()
        return SavedObjectShortcutService(
            tray: Tray(repository: repository, analyzer: AppleContentAnalyzer()),
            clipboard: SystemTextClipboard(),
            isAppLockEnabled: { AppLockPreference.isEnabled }
        )
    }
}

protocol SavedObjectSpotlightIndexing: Sendable {
    func replace(with entities: [SavedObjectEntity]) async throws
}

struct SavedObjectSpotlightSynchronizer: Sendable {
    let shortcutService: SavedObjectShortcutService
    let index: any SavedObjectSpotlightIndexing

    func synchronize(isEnabled: Bool) async throws {
        guard isEnabled else {
            try await index.replace(with: [])
            return
        }
        let entities: [SavedObjectEntity]
        do {
            entities = try await shortcutService.discoverableItems().map(SavedObjectEntity.init)
        } catch SavedObjectShortcutError.appLockEnabled {
            entities = []
        }
        try await index.replace(with: entities)
    }
}

struct SpotlightReconciliationState: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isPending: Bool {
        defaults.bool(forKey: SpotlightDiscoveryPreference.reconciliationPendingKey)
    }

    func markPending() {
        defaults.set(true, forKey: SpotlightDiscoveryPreference.reconciliationPendingKey)
    }

    func markComplete() {
        defaults.set(false, forKey: SpotlightDiscoveryPreference.reconciliationPendingKey)
    }
}

struct SavedObjectSpotlightLifecycle: Sendable {
    let synchronizer: SavedObjectSpotlightSynchronizer
    let state: SpotlightReconciliationState

    func synchronize(isEnabled: Bool) async {
        state.markPending()
        do {
            try await synchronizer.synchronize(isEnabled: isEnabled)
            state.markComplete()
        } catch {
            // Keep the durable pending marker so the next foreground reload retries.
        }
    }
}

enum SavedObjectSpotlightRuntime {
    @MainActor
    static func synchronize(
        tray: Tray,
        clipboard: any TextClipboard,
        isEnabled: Bool
    ) async {
        let service = SavedObjectShortcutService(
            tray: tray,
            clipboard: clipboard,
            isAppLockEnabled: { AppLockPreference.isEnabled }
        )
        await SavedObjectSpotlightLifecycle(
            synchronizer: SavedObjectSpotlightSynchronizer(
                shortcutService: service,
                index: CoreSpotlightSavedObjectIndex()
            ),
            state: SpotlightReconciliationState(defaults: SpotlightDiscoveryPreference.defaults)
        ).synchronize(isEnabled: isEnabled)
    }
}

struct CoreSpotlightSavedObjectIndex: SavedObjectSpotlightIndexing {
    private let index = CSSearchableIndex(
        name: "PocketTraySavedObjects",
        protectionClass: .complete
    )

    func replace(with entities: [SavedObjectEntity]) async throws {
        try await index.deleteAppEntities(ofType: SavedObjectEntity.self)
        if !entities.isEmpty {
            try await index.indexAppEntities(entities)
        }
    }
}

struct SavedObjectEntity: IndexedEntity, Transferable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Object")
    static let defaultQuery = SavedObjectEntityQuery()

    let id: UUID
    let title: String
    let kind: TrayItemKind

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind.displayName)"
        )
    }

    init(item: TrayItem) {
        id = item.id
        kind = item.kind
        title = Self.displayTitle(for: item)
    }

    private static func displayTitle(for item: TrayItem) -> String {
        let source = item.title ?? item.text
        let singleLine = source.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 80 ? String(singleLine.prefix(77)) + "…" : singleLine
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { entity in
            Data(try await SavedObjectShortcutService.live().text(id: entity.id).utf8)
        }
        .exportingCondition { $0.kind == .text }

        DataRepresentation(exportedContentType: .url) { entity in
            Data(try await SavedObjectShortcutService.live().url(id: entity.id).absoluteString.utf8)
        }
        .exportingCondition { $0.kind == .url }

        FileRepresentation(exportedContentType: .image) { entity in
            let resource = try await SavedObjectShortcutService.live().file(id: entity.id)
            return SentTransferredFile(resource.exportURL)
        }
        .exportingCondition { $0.kind == .image }

        FileRepresentation(exportedContentType: .pdf) { entity in
            let resource = try await SavedObjectShortcutService.live().file(id: entity.id)
            return SentTransferredFile(resource.exportURL)
        }
        .exportingCondition { $0.kind == .pdf }
    }
}

private extension TrayItemKind {
    var displayName: LocalizedStringResource {
        switch self {
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .url: "Link"
        }
    }
}

struct SavedObjectEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SavedObjectEntity] {
        let service = try SavedObjectShortcutService.live()
        let available = try await service.discoverableItems()
        let itemsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return identifiers.compactMap { itemsByID[$0].map(SavedObjectEntity.init) }
    }

    func suggestedEntities() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().discoverableItems().map(SavedObjectEntity.init)
    }

    func entities(matching string: String) async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().find(string)
            .map(SavedObjectEntity.init)
    }
}

struct CopyableSavedObjectOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().entities(withKinds: [.text, .url])
    }
}

struct SavedTextOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().entities(withKinds: [.text])
    }
}

struct SavedURLOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().entities(withKinds: [.url])
    }
}

struct SavedFileOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().entities(withKinds: [.image, .pdf])
    }
}

struct CopySavedObjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Saved Object"
    static let description = IntentDescription(
        "Open Pocket Tray and copy the current value of a saved text item or link."
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Object",
        requestValueDialog: "Which saved object?",
        optionsProvider: CopyableSavedObjectOptionsProvider()
    )
    var object: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$object)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await SavedObjectShortcutService.live().copy(id: object.id)
        return .result(dialog: "Copied \(SavedObjectEntity(item: item).title) from Pocket Tray.")
    }
}

struct FindSavedObjectsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Saved Objects"
    static let description = IntentDescription(
        "Find eligible Pocket Tray objects by title, text, or note."
    )

    @Parameter(title: "Search")
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find saved objects matching \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[SavedObjectEntity]> & ProvidesDialog {
        let items = try await SavedObjectShortcutService.live().find(query ?? "")
        let entities = items.map(SavedObjectEntity.init)
        return .result(
            value: entities,
            dialog: "Found \(entities.count) eligible Pocket Tray objects."
        )
    }
}

struct GetSavedTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Saved Text"
    static let description = IntentDescription(
        "Return the current text from an eligible Pocket Tray object for use in another Shortcuts action."
    )

    @Parameter(
        title: "Object",
        requestValueDialog: "Which saved text object?",
        optionsProvider: SavedTextOptionsProvider()
    )
    var object: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get text from \(\.$object)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let value = try await SavedObjectShortcutService.live().text(id: object.id)
        return .result(value: value, dialog: "Returned saved text from Pocket Tray.")
    }
}

struct GetSavedURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Saved Link"
    static let description = IntentDescription(
        "Return the URL from an eligible Pocket Tray link for use in another Shortcuts action."
    )

    @Parameter(
        title: "Object",
        requestValueDialog: "Which saved link?",
        optionsProvider: SavedURLOptionsProvider()
    )
    var object: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get link from \(\.$object)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let value = try await SavedObjectShortcutService.live().url(id: object.id)
        return .result(value: value, dialog: "Returned a saved link from Pocket Tray.")
    }
}

struct GetSavedFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Saved Image or PDF"
    static let description = IntentDescription(
        "Return the original image or PDF from Pocket Tray for Share or another compatible Shortcuts action."
    )

    @Parameter(
        title: "Object",
        requestValueDialog: "Which saved image or PDF?",
        optionsProvider: SavedFileOptionsProvider()
    )
    var object: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get file from \(\.$object)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let resource = try await SavedObjectShortcutService.live().file(id: object.id)
        let value = IntentFile(
            data: resource.data,
            filename: resource.exportURL.lastPathComponent,
            type: UTType(resource.asset.typeIdentifier) ?? .data
        )
        return .result(value: value, dialog: "Returned the original file from Pocket Tray.")
    }
}

enum SavedObjectOpenHandoff {
    private static let key = "shortcut.openSavedObjectID"

    static func requestOpen(id: UUID) {
        UserDefaults(suiteName: FileTrayRepository.appGroupIdentifier)?.set(id.uuidString, forKey: key)
    }

    static func consumeOpenRequest() -> UUID? {
        guard let defaults = UserDefaults(suiteName: FileTrayRepository.appGroupIdentifier),
              let value = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return UUID(uuidString: value)
    }
}

struct OpenSavedObjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Saved Object"
    static let description = IntentDescription("Open a saved text item or link in Pocket Tray.")

    @Parameter(title: "Object", requestValueDialog: "Which saved object?")
    var target: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let item = try await SavedObjectShortcutService.live().resolve(id: target.id)
        SavedObjectOpenHandoff.requestOpen(id: item.id)
        return .result()
    }
}
