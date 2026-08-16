import Foundation

enum TrayError: Error, Equatable, LocalizedError {
    case emptyText
    case itemNotFound
    case unsupportedContent

    var errorDescription: String? {
        switch self {
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
    case text(String)
    case url(URL)
    case unsupported
}

enum TrayItemKind: String, Codable, Equatable, Sendable {
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

    func recaptured(with candidate: TrayItem) -> TrayItem {
        var updated = self
        updated.kind = candidate.kind
        updated.text = candidate.text
        updated.capturedAt = candidate.capturedAt
        updated.expiresAt = isPinned ? nil : candidate.expiresAt
        updated.state = .recent
        updated.trashedAt = nil
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

    var contentIdentity: String {
        text
    }
}

protocol TrayRepository: Sendable {
    func save(_ item: TrayItem) async throws -> TrayItem
    func setPinned(_ id: UUID, to isPinned: Bool, at date: Date) async throws -> TrayItem?
    func moveToTrash(_ id: UUID, at date: Date) async throws -> TrayItem?
    func restore(_ id: UUID, at date: Date) async throws -> TrayItem?
    func deletePermanently(_ id: UUID) async throws -> Bool
    func items(at date: Date) async throws -> [TrayItem]
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
        switch content {
        case let .text(value):
            if let url = Self.webURL(from: value) {
                kind = .url
                text = url.absoluteString
            } else {
                kind = .text
                text = value
            }
        case let .url(url):
            guard Self.isWebURL(url) else {
                throw TrayError.unsupportedContent
            }
            kind = .url
            text = url.absoluteString
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
            expiresAt: capturedAt.addingTimeInterval(TrayRetention.recent)
        )
        return try await repository.save(item)
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
        let items = try await repository.items(at: now())
        let recent = items.filter { $0.state == .recent }.newestFirst()
        return TraySnapshot(
            recent: recent,
            pinned: recent.filter(\.isPinned),
            trash: items
                .filter { $0.state == .trash }
                .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
        )
    }

    func setPinned(_ id: UUID, to isPinned: Bool) async throws -> TrayItem {
        guard let item = try await repository.setPinned(id, to: isPinned, at: now()) else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func moveToTrash(_ id: UUID) async throws -> TrayItem {
        guard let item = try await repository.moveToTrash(id, at: now()) else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func restore(_ id: UUID) async throws -> TrayItem {
        guard let item = try await repository.restore(id, at: now()) else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func deletePermanently(_ id: UUID) async throws {
        guard try await repository.deletePermanently(id) else {
            throw TrayError.itemNotFound
        }
    }

    func reuse(_ item: TrayItem, using clipboard: any TextClipboard) async throws {
        try await clipboard.copy(item.text)
    }
}

struct TraySnapshot: Equatable, Sendable {
    static let empty = TraySnapshot(recent: [], pinned: [], trash: [])

    let recent: [TrayItem]
    let pinned: [TrayItem]
    let trash: [TrayItem]
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
            $0.contentIdentity == candidate.contentIdentity
        }
        guard let existing = matches.max(by: { $0.capturedAt < $1.capturedAt }) else {
            append(candidate)
            return candidate
        }

        let updated = existing.recaptured(with: candidate)
        removeAll {
            $0.contentIdentity == candidate.contentIdentity
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
}

actor InMemoryTrayRepository: TrayRepository {
    private var items: [TrayItem]

    init(items: [TrayItem] = []) {
        self.items = items
    }

    func save(_ item: TrayItem) -> TrayItem {
        items.saveCapture(item)
    }

    func setPinned(_ id: UUID, to isPinned: Bool, at date: Date) -> TrayItem? {
        items.setPinned(id, to: isPinned, at: date)
    }

    func moveToTrash(_ id: UUID, at date: Date) -> TrayItem? {
        items.moveToTrash(id, at: date)
    }

    func restore(_ id: UUID, at date: Date) -> TrayItem? {
        items.restore(id, at: date)
    }

    func deletePermanently(_ id: UUID) -> Bool {
        items.deletePermanently(id)
    }

    func items(at date: Date) -> [TrayItem] {
        items.maintainLifecycle(at: date)
        return items
    }
}
