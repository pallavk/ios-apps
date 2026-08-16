import Foundation

enum TrayError: Error, Equatable, LocalizedError {
    case collectionNotFound
    case emptyCollectionName
    case emptyText
    case itemNotFound
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .collectionNotFound:
            "That collection is no longer available."
        case .emptyCollectionName:
            "A collection needs a name."
        case .emptyText:
            "The clipboard does not contain text to save."
        case .itemNotFound:
            "That Pocket Tray object is no longer available."
        case .unsupportedContent:
            "That clipboard content is not supported yet."
        }
    }
}

enum CaptureContent: Equatable, Sendable {
    case image(ImagePayload)
    case pdf(PDFPayload)
    case text(String)
    case url(URL)
    case unsupported
}

enum TrayItemKind: String, Codable, Equatable, Sendable {
    case image
    case pdf
    case text
    case url
}

enum TrayItemState: String, Codable, Equatable, Sendable {
    case recent
    case trash
}

enum TrayRetention {
    static let recent: TimeInterval = 7 * 24 * 60 * 60
    static let trash: TimeInterval = 7 * 24 * 60 * 60
}

struct TrayItem: Codable, Equatable, Identifiable, Sendable {
    private(set) var id: UUID
    private(set) var kind: TrayItemKind
    private(set) var text: String
    private(set) var createdAt: Date
    private(set) var capturedAt: Date
    private(set) var isPinned: Bool
    private(set) var title: String?
    private(set) var note: String?
    private(set) var collectionID: UUID?
    private(set) var asset: TrayAsset?
    private(set) var deduplicationKeys: Set<String>
    private(set) var expiresAt: Date?
    private(set) var state: TrayItemState
    private(set) var trashedAt: Date?

    init(
        id: UUID,
        kind: TrayItemKind = .text,
        text: String,
        createdAt: Date? = nil,
        capturedAt: Date,
        isPinned: Bool = false,
        title: String? = nil,
        note: String? = nil,
        collectionID: UUID? = nil,
        asset: TrayAsset? = nil,
        deduplicationKeys: Set<String>? = nil,
        expiresAt: Date? = nil,
        state: TrayItemState = .recent,
        trashedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt ?? capturedAt
        self.capturedAt = capturedAt
        self.isPinned = isPinned
        self.title = title
        self.note = note
        self.collectionID = collectionID
        self.asset = asset
        self.deduplicationKeys = deduplicationKeys ?? [asset?.digest ?? text]
        self.expiresAt = expiresAt
        self.state = state
        self.trashedAt = trashedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case createdAt
        case capturedAt
        case isPinned
        case title
        case note
        case collectionID
        case asset
        case deduplicationKeys
        case deduplicationKey
        case expiresAt
        case state
        case trashedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(TrayItemKind.self, forKey: .kind) ?? .text
        text = try container.decode(String.self, forKey: .text)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? capturedAt
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        collectionID = try container.decodeIfPresent(UUID.self, forKey: .collectionID)
        asset = try container.decodeIfPresent(TrayAsset.self, forKey: .asset)
        if let storedKeys = try container.decodeIfPresent(Set<String>.self, forKey: .deduplicationKeys) {
            deduplicationKeys = storedKeys.union([asset?.digest ?? text])
        } else if let legacyKey = try container.decodeIfPresent(String.self, forKey: .deduplicationKey) {
            deduplicationKeys = [legacyKey, asset?.digest ?? text]
        } else {
            deduplicationKeys = [asset?.digest ?? text]
        }
        state = try container.decodeIfPresent(TrayItemState.self, forKey: .state) ?? .recent
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        let storedExpiry = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        if let storedExpiry {
            expiresAt = storedExpiry
        } else if !isPinned && state == .recent {
            expiresAt = capturedAt.addingTimeInterval(TrayRetention.recent)
        } else {
            expiresAt = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(collectionID, forKey: .collectionID)
        try container.encodeIfPresent(asset, forKey: .asset)
        try container.encode(deduplicationKeys, forKey: .deduplicationKeys)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(trashedAt, forKey: .trashedAt)
    }

    func recaptured(with candidate: TrayItem) -> TrayItem {
        var updated = self
        if text == candidate.text {
            updated.kind = candidate.kind
        }
        updated.capturedAt = candidate.capturedAt
        updated.deduplicationKeys.formUnion(candidate.deduplicationKeys)
        updated.expiresAt = isPinned ? nil : candidate.expiresAt
        updated.state = .recent
        updated.trashedAt = nil
        return updated
    }

    func mergingDeduplicationKeys(_ keys: Set<String>) -> TrayItem {
        var updated = self
        updated.deduplicationKeys.formUnion(keys)
        return updated
    }

    func applying(_ edits: TrayItemEdits) -> TrayItem {
        var updated = self
        if asset == nil {
            updated.kind = edits.kind
            updated.text = edits.text
            updated.deduplicationKeys.insert(edits.text)
        }
        updated.title = edits.title
        updated.note = edits.note
        updated.collectionID = edits.collectionID
        return updated
    }

    func assigning(to collectionID: UUID?) -> TrayItem {
        var updated = self
        updated.collectionID = collectionID
        return updated
    }

    func settingPinned(_ isPinned: Bool, at date: Date) -> TrayItem {
        var updated = self
        updated.isPinned = isPinned
        updated.expiresAt = isPinned ? nil : date.addingTimeInterval(TrayRetention.recent)
        return updated
    }

    func movingToTrash(at date: Date) -> TrayItem {
        var updated = self
        updated.isPinned = false
        updated.expiresAt = nil
        updated.state = .trash
        updated.trashedAt = date
        return updated
    }

    func restoring(at date: Date) -> TrayItem {
        var updated = self
        updated.isPinned = false
        updated.expiresAt = date.addingTimeInterval(TrayRetention.recent)
        updated.state = .recent
        updated.trashedAt = nil
        return updated
    }

}

struct TrayItemEdits: Equatable, Sendable {
    let kind: TrayItemKind
    let text: String
    let title: String?
    let note: String?
    let collectionID: UUID?
}

struct TrayCollection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    private(set) var name: String
    let createdAt: Date

    func renamed(to name: String) -> TrayCollection {
        TrayCollection(id: id, name: name, createdAt: createdAt)
    }
}

struct TrayStore: Codable, Equatable, Sendable {
    static let empty = TrayStore()

    var items: [TrayItem]
    var collections: [TrayCollection]

    init(items: [TrayItem] = [], collections: [TrayCollection] = []) {
        self.items = items
        self.collections = collections
    }
}

enum TrayMutation: Sendable {
    case capture(TrayItem, assetWrite: TrayAssetWrite?)
    case setPinned(UUID, Bool, Date)
    case moveToTrash(UUID, Date)
    case restore(UUID, Date)
    case deletePermanently(UUID)
    case edit(UUID, TrayItemEdits, Date)
    case createCollection(TrayCollection)
    case assign(UUID, UUID?, Date)
    case renameCollection(UUID, String)
    case deleteCollection(UUID)
}

enum TrayMutationResult: Sendable {
    case item(TrayItem?)
    case collection(TrayCollection?)
    case success(Bool)

    var item: TrayItem? {
        get throws {
            guard case let .item(item) = self else {
                throw TrayRepositoryContractError.unexpectedMutationResult
            }
            return item
        }
    }

    var collection: TrayCollection? {
        get throws {
            guard case let .collection(collection) = self else {
                throw TrayRepositoryContractError.unexpectedMutationResult
            }
            return collection
        }
    }

    var succeeded: Bool {
        get throws {
            guard case let .success(succeeded) = self else {
                throw TrayRepositoryContractError.unexpectedMutationResult
            }
            return succeeded
        }
    }
}

private enum TrayRepositoryContractError: Error {
    case unexpectedMutationResult
}

protocol TrayRepository: Sendable {
    func apply(_ mutation: TrayMutation) async throws -> TrayMutationResult
    func resource(for asset: TrayAsset) async throws -> TrayAssetResource
    func store(at date: Date) async throws -> TrayStore
}

protocol TextClipboard: Sendable {
    func copy(_ text: String) async throws
}

struct Tray: Sendable {
    private let repository: any TrayRepository
    private let now: @Sendable () -> Date

    init(
        repository: any TrayRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
    }

    func capture(_ content: CaptureContent) async throws -> TrayItem {
        let kind: TrayItemKind
        let text: String
        let assetWrite: TrayAssetWrite?
        switch content {
        case let .image(payload):
            let write = try ImageAssetFactory.makeWrite(from: payload)
            kind = .image
            let suggestedName = payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let suggestedName, !suggestedName.isEmpty {
                text = suggestedName
            } else {
                text = "Image"
            }
            assetWrite = write
        case let .pdf(payload):
            let write = try PDFAssetFactory.makeWrite(from: payload)
            kind = .pdf
            let suggestedName = payload.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let suggestedName, !suggestedName.isEmpty {
                text = suggestedName
            } else {
                text = "PDF Document"
            }
            assetWrite = write
        case let .text(value):
            if let url = Self.webURL(from: value) {
                kind = .url
                text = url.absoluteString
            } else {
                kind = .text
                text = value
            }
            assetWrite = nil
        case let .url(url):
            guard Self.isWebURL(url) else {
                throw TrayError.unsupportedContent
            }
            kind = .url
            text = url.absoluteString
            assetWrite = nil
        case .unsupported:
            throw TrayError.unsupportedContent
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrayError.emptyText
        }
        let capturedAt = now()
        let item = TrayItem(
            id: UUID(),
            kind: kind,
            text: text,
            capturedAt: capturedAt,
            asset: assetWrite?.asset,
            expiresAt: capturedAt.addingTimeInterval(TrayRetention.recent)
        )
        try Task.checkCancellation()
        guard let saved = try await repository.apply(
            .capture(item, assetWrite: assetWrite)
        ).item else {
            throw TrayError.itemNotFound
        }
        return saved
    }

    private static func webURL(from text: String) -> URL? {
        guard let url = URL(string: text), isWebURL(url) else {
            return nil
        }
        return url
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host() != nil
    }

    func recent() async throws -> [TrayItem] {
        try await snapshot().recent
    }

    func trash() async throws -> [TrayItem] {
        try await snapshot().trash
    }

    func pinned() async throws -> [TrayItem] {
        try await snapshot().pinned
    }

    func snapshot() async throws -> TraySnapshot {
        let store = try await repository.store(at: now())
        let recent = store.items.filter { $0.state == .recent }.newestFirst()
        return TraySnapshot(
            recent: recent,
            pinned: recent.filter(\.isPinned),
            trash: store.items
                .filter { $0.state == .trash }
                .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) },
            collections: store.collections.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    func createCollection(named name: String) async throws -> TrayCollection {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TrayError.emptyCollectionName
        }
        let collection = TrayCollection(id: UUID(), name: normalizedName, createdAt: now())
        guard let created = try await repository.apply(.createCollection(collection)).collection else {
            throw TrayError.collectionNotFound
        }
        return created
    }

    func assign(_ itemID: UUID, to collectionID: UUID?) async throws -> TrayItem {
        guard let item = try await repository.apply(.assign(itemID, collectionID, now())).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func renameCollection(_ id: UUID, to name: String) async throws -> TrayCollection {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TrayError.emptyCollectionName
        }
        guard let collection = try await repository.apply(.renameCollection(id, normalizedName)).collection else {
            throw TrayError.collectionNotFound
        }
        return collection
    }

    func deleteCollection(_ id: UUID) async throws {
        guard try await repository.apply(.deleteCollection(id)).succeeded else {
            throw TrayError.collectionNotFound
        }
    }

    func search(_ query: String) async throws -> [TrayItem] {
        try await snapshot().search(query)
    }

    func setPinned(_ id: UUID, to isPinned: Bool) async throws -> TrayItem {
        guard let item = try await repository.apply(.setPinned(id, isPinned, now())).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func moveToTrash(_ id: UUID) async throws -> TrayItem {
        guard let item = try await repository.apply(.moveToTrash(id, now())).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func restore(_ id: UUID) async throws -> TrayItem {
        guard let item = try await repository.apply(.restore(id, now())).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func deletePermanently(_ id: UUID) async throws {
        guard try await repository.apply(.deletePermanently(id)).succeeded else {
            throw TrayError.itemNotFound
        }
    }

    func edit(
        _ id: UUID,
        text: String,
        title: String?,
        note: String?,
        collectionID: UUID? = nil
    ) async throws -> TrayItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrayError.emptyText
        }
        let edits = TrayItemEdits(
            kind: Self.webURL(from: text) == nil ? .text : .url,
            text: text,
            title: Self.nonBlank(title),
            note: Self.nonBlank(note),
            collectionID: collectionID
        )
        guard let item = try await repository.apply(.edit(id, edits, now())).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    func reuse(_ item: TrayItem, using clipboard: any TextClipboard) async throws {
        try await clipboard.copy(item.text)
    }

    func assetResource(for item: TrayItem) async throws -> TrayAssetResource {
        guard let asset = item.asset else {
            throw TrayAssetError.missing
        }
        return try await repository.resource(for: asset)
    }
}

struct TraySnapshot: Equatable, Sendable {
    static let empty = TraySnapshot(recent: [], pinned: [], trash: [], collections: [])

    let recent: [TrayItem]
    let pinned: [TrayItem]
    let trash: [TrayItem]
    let collections: [TrayCollection]

    func search(_ query: String) -> [TrayItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return recent }
        let collectionNames = Dictionary(
            uniqueKeysWithValues: collections.map { ($0.id, $0.name) }
        )
        return recent.filter { item in
            let values = [
                item.text,
                item.title,
                item.note,
                item.collectionID.flatMap { collectionNames[$0] }
            ].compactMap { $0 }
            return values.contains { value in
                value.range(
                    of: normalizedQuery,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }
}

extension TrayStore {
    mutating func apply(_ mutation: TrayMutation) -> TrayMutationResult {
        switch mutation {
        case let .capture(item, assetWrite: _):
            .item(items.saveCapture(item))
        case let .setPinned(id, isPinned, date):
            .item(items.setPinned(id, to: isPinned, at: date))
        case let .moveToTrash(id, date):
            .item(items.moveToTrash(id, at: date))
        case let .restore(id, date):
            .item(items.restore(id, at: date))
        case let .deletePermanently(id):
            .success(items.deletePermanently(id))
        case let .edit(id, edits, date):
            .item(edit(id, edits: edits, at: date))
        case let .createCollection(collection):
            createCollection(collection)
        case let .assign(itemID, collectionID, date):
            .item(assign(itemID, to: collectionID, at: date))
        case let .renameCollection(id, name):
            .collection(renameCollection(id, to: name))
        case let .deleteCollection(id):
            .success(deleteCollection(id))
        }
    }

    private mutating func createCollection(_ collection: TrayCollection) -> TrayMutationResult {
        collections.append(collection)
        return .collection(collection)
    }

    mutating func edit(_ id: UUID, edits: TrayItemEdits, at date: Date) -> TrayItem? {
        guard edits.collectionID == nil || collections.contains(where: { $0.id == edits.collectionID }) else {
            return nil
        }
        return items.edit(id, edits: edits, at: date)
    }

    mutating func assign(_ itemID: UUID, to collectionID: UUID?, at date: Date) -> TrayItem? {
        items.maintainLifecycle(at: date)
        guard
            collectionID == nil || collections.contains(where: { $0.id == collectionID }),
            let index = items.firstIndex(where: { $0.id == itemID && $0.state == .recent })
        else {
            return nil
        }
        let updated = items[index].assigning(to: collectionID)
        items[index] = updated
        return updated
    }

    mutating func renameCollection(_ id: UUID, to name: String) -> TrayCollection? {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return nil }
        let renamed = collections[index].renamed(to: name)
        collections[index] = renamed
        return renamed
    }

    mutating func deleteCollection(_ id: UUID) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        collections.remove(at: index)
        for itemIndex in items.indices where items[itemIndex].collectionID == id {
            items[itemIndex] = items[itemIndex].assigning(to: nil)
        }
        return true
    }
}

extension Sequence where Element == TrayItem {
    func newestFirst() -> [TrayItem] {
        sorted { $0.capturedAt > $1.capturedAt }
    }
}

extension Array where Element == TrayItem {
    mutating func maintainLifecycle(at date: Date) {
        for index in indices where self[index].state == .recent {
            let item = self[index]
            if !item.isPinned, let expiresAt = item.expiresAt, expiresAt <= date {
                self[index] = item.movingToTrash(at: expiresAt)
            }
        }
        removeAll { item in
            guard item.state == .trash, let trashedAt = item.trashedAt else { return false }
            return trashedAt.addingTimeInterval(TrayRetention.trash) <= date
        }
    }

    mutating func saveCapture(_ candidate: TrayItem) -> TrayItem {
        maintainLifecycle(at: candidate.capturedAt)
        let matches = filter {
            !$0.deduplicationKeys.isDisjoint(with: candidate.deduplicationKeys)
        }
        guard let existing = matches.max(by: { $0.capturedAt < $1.capturedAt }) else {
            append(candidate)
            return candidate
        }

        var updated = existing.recaptured(with: candidate)
        for match in matches {
            updated = updated.mergingDeduplicationKeys(match.deduplicationKeys)
        }
        removeAll {
            !$0.deduplicationKeys.isDisjoint(with: candidate.deduplicationKeys)
        }
        append(updated)
        return updated
    }

    mutating func setPinned(_ id: UUID, to isPinned: Bool, at date: Date) -> TrayItem? {
        maintainLifecycle(at: date)
        guard let index = firstIndex(where: { $0.id == id && $0.state == .recent }) else {
            return nil
        }
        let updated = self[index].settingPinned(isPinned, at: date)
        self[index] = updated
        return updated
    }

    mutating func moveToTrash(_ id: UUID, at date: Date) -> TrayItem? {
        maintainLifecycle(at: date)
        guard let index = firstIndex(where: { $0.id == id && $0.state == .recent }) else {
            return nil
        }
        let updated = self[index].movingToTrash(at: date)
        self[index] = updated
        return updated
    }

    mutating func restore(_ id: UUID, at date: Date) -> TrayItem? {
        maintainLifecycle(at: date)
        guard let index = firstIndex(where: { $0.id == id && $0.state == .trash }) else {
            return nil
        }
        let updated = self[index].restoring(at: date)
        self[index] = updated
        return updated
    }

    mutating func deletePermanently(_ id: UUID) -> Bool {
        guard let index = firstIndex(where: { $0.id == id && $0.state == .trash }) else {
            return false
        }
        remove(at: index)
        return true
    }

    mutating func edit(_ id: UUID, edits: TrayItemEdits, at date: Date) -> TrayItem? {
        maintainLifecycle(at: date)
        guard let index = firstIndex(where: { $0.id == id && $0.state == .recent }) else {
            return nil
        }
        let updated = self[index].applying(edits)
        self[index] = updated
        return updated
    }
}

actor InMemoryTrayRepository: TrayRepository {
    private var store: TrayStore
    private let assetStore: AssetStore

    init(
        items: [TrayItem] = [],
        collections: [TrayCollection] = [],
        assetDirectoryURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "PocketTrayTests-\(UUID().uuidString)"),
        assetWriter: any AssetDataWriting = AtomicAssetDataWriter()
    ) {
        self.store = TrayStore(items: items, collections: collections)
        self.assetStore = AssetStore(
            directoryURL: assetDirectoryURL,
            writer: assetWriter
        )
    }

    func apply(_ mutation: TrayMutation) throws -> TrayMutationResult {
        try Task.checkCancellation()
        if case let .capture(_, assetWrite: assetWrite?) = mutation {
            try assetStore.persist(assetWrite)
            try Task.checkCancellation()
        }
        return store.apply(mutation)
    }

    func resource(for asset: TrayAsset) throws -> TrayAssetResource {
        try assetStore.resource(for: asset)
    }

    func store(at date: Date) -> TrayStore {
        store.items.maintainLifecycle(at: date)
        return store
    }
}
