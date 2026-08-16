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

enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case unsupported
}

struct TrayItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let capturedAt: Date
}

protocol TrayRepository: Sendable {
    func save(_ item: TrayItem) async throws
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

    func capture(_ content: ClipboardContent) async throws -> TrayItem {
        guard case let .text(text) = content else {
            throw TrayError.unsupportedContent
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrayError.emptyText
        }
        let item = TrayItem(id: UUID(), text: text, capturedAt: now())
        try await repository.save(item)
        return item
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

actor InMemoryTrayRepository: TrayRepository {
    private var items: [TrayItem]

    init(items: [TrayItem] = []) {
        self.items = items
    }

    func save(_ item: TrayItem) {
        items.append(item)
    }

    func recent() -> [TrayItem] {
        items.newestFirst()
    }
}
