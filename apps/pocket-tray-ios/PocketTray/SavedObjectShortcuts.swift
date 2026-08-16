import AppIntents
import Foundation

enum SavedObjectShortcutError: Error, Equatable, LocalizedError {
    case appLockEnabled
    case itemUnavailable

    var errorDescription: String? {
        switch self {
        case .appLockEnabled:
            "Pocket Tray is locked. Open the app and authenticate before reusing saved objects."
        case .itemUnavailable:
            "That Pocket Tray object is no longer available. Choose another saved object."
        }
    }
}

struct SavedObjectShortcutService: Sendable {
    let tray: Tray
    let clipboard: any TextClipboard
    let isAppLockEnabled: @Sendable () async -> Bool

    func suggestedItems() async throws -> [TrayItem] {
        guard !(await isAppLockEnabled()) else {
            throw SavedObjectShortcutError.appLockEnabled
        }
        return try await tray.recent()
            .filter { item in
                (item.kind == .text || item.kind == .url) && !item.protectsSensitivePreview
            }
            .sorted { left, right in
                if left.isPinned != right.isPinned { return left.isPinned }
                return left.capturedAt > right.capturedAt
            }
    }

    func resolve(id: UUID) async throws -> TrayItem {
        guard let item = try await suggestedItems().first(where: { $0.id == id }) else {
            throw SavedObjectShortcutError.itemUnavailable
        }
        return item
    }

    func copy(id: UUID) async throws -> TrayItem {
        let item = try await resolve(id: id)
        try await tray.reuse(item, using: clipboard)
        return item
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

struct SavedObjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Object")
    static let defaultQuery = SavedObjectEntityQuery()

    let id: UUID
    let title: String
    let kind: TrayItemKind

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: kind == .url ? "Link" : "Text"
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
}

struct SavedObjectEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SavedObjectEntity] {
        let service = try SavedObjectShortcutService.live()
        let available = try await service.suggestedItems()
        let itemsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return identifiers.compactMap { itemsByID[$0].map(SavedObjectEntity.init) }
    }

    func suggestedEntities() async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().suggestedItems().map(SavedObjectEntity.init)
    }

    func entities(matching string: String) async throws -> [SavedObjectEntity] {
        try await SavedObjectShortcutService.live().suggestedItems()
            .filter { item in
                [item.title, item.text, item.note]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(string) }
            }
            .map(SavedObjectEntity.init)
    }
}

struct CopySavedObjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Saved Object"
    static let description = IntentDescription(
        "Copy the current value of a saved Pocket Tray text item or link."
    )

    @Parameter(title: "Object", requestValueDialog: "Which saved object?")
    var object: SavedObjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$object)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await SavedObjectShortcutService.live().copy(id: object.id)
        return .result(dialog: "Copied \(SavedObjectEntity(item: item).title) from Pocket Tray.")
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
