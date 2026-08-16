import Foundation

enum TrayError: Error, Equatable, LocalizedError {
    case emptyText
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "The clipboard does not contain text to save."
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

struct TrayItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: TrayItemKind
    let text: String
    let createdAt: Date
    let capturedAt: Date
    let isPinned: Bool
    let title: String?
    let note: String?
    let collectionID: UUID?
    let expiresAt: Date?

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
        expiresAt: Date? = nil
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
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    func recaptured(with candidate: TrayItem) -> TrayItem {
        TrayItem(
            id: id,
            kind: candidate.kind,
            text: candidate.text,
            createdAt: createdAt,
            capturedAt: candidate.capturedAt,
            isPinned: isPinned,
            title: title,
            note: note,
            collectionID: collectionID,
            expiresAt: isPinned ? nil : candidate.expiresAt
        )
    }

    var contentIdentity: String {
        text
    }
}

protocol TrayRepository: Sendable {
    func save(_ item: TrayItem) async throws -> TrayItem
    func recent() async throws -> [TrayItem]
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
            expiresAt: capturedAt.addingTimeInterval(7 * 24 * 60 * 60)
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
        try await repository.recent()
    }

    func reuse(_ item: TrayItem, using clipboard: any TextClipboard) async throws {
        try await clipboard.copy(item.text)
    }
}

extension Sequence where Element == TrayItem {
    func newestFirst() -> [TrayItem] {
        sorted { $0.capturedAt > $1.capturedAt }
    }
}

extension Array where Element == TrayItem {
    mutating func saveCapture(_ candidate: TrayItem) -> TrayItem {
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
}

actor InMemoryTrayRepository: TrayRepository {
    private var items: [TrayItem]

    init(items: [TrayItem] = []) {
        self.items = items
    }

    func save(_ item: TrayItem) -> TrayItem {
        items.saveCapture(item)
    }

    func recent() -> [TrayItem] {
        items.newestFirst()
    }
}
