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

    var suggestedTitle: String {
        switch kind {
        case .url:
            let destination = target.flatMap(URL.init(string:))?.host() ?? value
            return "Open \(destination)"
        case .phone:
            return "Call \(value)"
        case .address:
            return target == nil ? "Copy \(value)" : "Open \(value) in Maps"
        case .date:
            return target == nil ? "Copy \(value)" : "Open \(value) in Calendar"
        case .trackingNumber:
            return target == nil ? "Copy tracking number \(value)" : "Track \(value)"
        }
    }
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
    private let maxConcurrentOperations: Int
    private var inFlight: Set<UUID> = []
    private var pending: [UUID: @Sendable () async -> Void] = [:]
    private var queuedItemIDs: [UUID] = []
    private var queuedOperations: [UUID: @Sendable () async -> Void] = [:]
    private var runningOperations = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentOperations: Int = 2) {
        precondition(maxConcurrentOperations > 0)
        self.maxConcurrentOperations = maxConcurrentOperations
    }

    func schedule(
        itemID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) {
        guard inFlight.insert(itemID).inserted else {
            if queuedOperations[itemID] != nil {
                queuedOperations[itemID] = operation
            } else {
                pending[itemID] = operation
            }
            return
        }
        queuedItemIDs.append(itemID)
        queuedOperations[itemID] = operation
        startAvailableOperations()
    }

    private func startAvailableOperations() {
        while runningOperations < maxConcurrentOperations, !queuedItemIDs.isEmpty {
            let itemID = queuedItemIDs.removeFirst()
            guard let operation = queuedOperations.removeValue(forKey: itemID) else {
                continue
            }
            runningOperations += 1
            Task {
                await operation()
                finished(itemID)
            }
        }
    }

    private func finished(_ itemID: UUID) {
        runningOperations -= 1
        if let operation = pending.removeValue(forKey: itemID) {
            queuedItemIDs.append(itemID)
            queuedOperations[itemID] = operation
        } else {
            inFlight.remove(itemID)
        }
        startAvailableOperations()
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
