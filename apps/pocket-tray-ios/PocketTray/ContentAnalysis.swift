import Foundation

enum ContentEntityKind: String, Codable, Equatable, Sendable {
    case organization
    case person
    case place
}

struct ContentEntity: Codable, Equatable, Sendable {
    let kind: ContentEntityKind
    let value: String
}

enum ContentActionKind: String, Codable, Equatable, Sendable {
    case address
    case date
    case phone
    case trackingNumber
    case url
}

struct ContentAction: Codable, Equatable, Identifiable, Sendable {
    let kind: ContentActionKind
    let value: String
    let target: String?

    var id: String { "\(kind.rawValue)\u{0}\(value)" }
}

struct ContentAnalysis: Codable, Equatable, Sendable {
    let searchableText: String?
    let languageCode: String?
    let entities: [ContentEntity]
    let actions: [ContentAction]
}

struct ContentAnalysisInput: Equatable, Sendable {
    let itemID: UUID
    let kind: TrayItemKind
    let text: String
    let assetData: Data?
    let assetTypeIdentifier: String?
}

protocol ContentAnalyzing: Sendable {
    func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis
}

struct UnavailableContentAnalyzer: ContentAnalyzing {
    enum Failure: Error { case unavailable }
    func analyze(_ input: ContentAnalysisInput) async throws -> ContentAnalysis {
        throw Failure.unavailable
    }
}

actor ContentAnalysisScheduler {
    private var inFlight: Set<UUID> = []
    private var pending: [UUID: @Sendable () async -> Void] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func schedule(
        itemID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) {
        guard inFlight.insert(itemID).inserted else {
            pending[itemID] = operation
            return
        }
        start(itemID: itemID, operation: operation)
    }

    private func start(
        itemID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) {
        Task {
            await operation()
            finished(itemID)
        }
    }

    private func finished(_ itemID: UUID) {
        if let operation = pending.removeValue(forKey: itemID) {
            start(itemID: itemID, operation: operation)
            return
        }
        inFlight.remove(itemID)
        if inFlight.isEmpty {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilIdle() async {
        guard !inFlight.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}
