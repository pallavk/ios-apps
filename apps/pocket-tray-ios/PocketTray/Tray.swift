import Foundation

enum TrayError: Error, Equatable, LocalizedError {
    case collectionNotFound
    case emptyCollectionName
    case emptyText
    case itemNotFound
    case sensitiveContentRequiresAcknowledgment([SensitiveContentReason])
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .collectionNotFound:
            String(localized: "That collection is no longer available.")
        case .emptyCollectionName:
            String(localized: "A collection needs a name.")
        case .emptyText:
            String(localized: "The clipboard does not contain text to save.")
        case .itemNotFound:
            String(localized: "That Pocket Tray object is no longer available.")
        case let .sensitiveContentRequiresAcknowledgment(reasons):
            String(localized: "This may contain sensitive content: \(reasons.map(\.warningLabel).joined(separator: ", ")). Review it before saving.")
        case .unsupportedContent:
            String(localized: "That clipboard content is not supported yet.")
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

protocol TextClipboard: Sendable {
    func copy(_ text: String) async throws
}

struct PreparedTrayCapture: Sendable {
    let item: TrayItem
    let assetWrite: TrayAssetWrite?
}

struct Tray: Sendable {
    private let repository: any TrayRepository
    private let now: @Sendable () -> Date
    private let analyzer: any ContentAnalyzing
    private let analysisScheduler: ContentAnalysisScheduler
    private let sensitiveContentClassifier: any SensitiveContentClassifying

    init(
        repository: any TrayRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        analyzer: any ContentAnalyzing = UnavailableContentAnalyzer(),
        analysisScheduler: ContentAnalysisScheduler = ContentAnalysisScheduler(),
        sensitiveContentClassifier: any SensitiveContentClassifying = DeterministicSensitiveContentClassifier()
    ) {
        self.repository = repository
        self.now = now
        self.analyzer = analyzer
        self.analysisScheduler = analysisScheduler
        self.sensitiveContentClassifier = sensitiveContentClassifier
    }

    func capture(_ content: CaptureContent) async throws -> TrayItem {
        try await commit(prepareCapture(content))
    }

    func prepareCapture(_ content: CaptureContent) throws -> PreparedTrayCapture {
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
            sensitivity: assessment(for: text),
            expiresAt: capturedAt.addingTimeInterval(TrayRetention.recent)
        )
        return PreparedTrayCapture(item: item, assetWrite: assetWrite)
    }

    func commit(
        _ prepared: PreparedTrayCapture,
        acknowledgingSensitiveContent: Bool = false
    ) async throws -> TrayItem {
        try Task.checkCancellation()
        if
            let assessment = prepared.item.sensitivity,
            !assessment.isOverridden,
            !acknowledgingSensitiveContent
        {
            throw TrayError.sensitiveContentRequiresAcknowledgment(
                SensitiveContentReason.ordered(assessment.reasons)
            )
        }
        guard let saved = try await repository.apply(
            .capture(prepared.item, assetWrite: prepared.assetWrite)
        ).item else {
            throw TrayError.itemNotFound
        }
        await scheduleAnalysis(for: saved)
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

    func snapshot(rescheduleMissingAnalysis: Bool = true) async throws -> TraySnapshot {
        let store = try await repository.store(at: now())
        if rescheduleMissingAnalysis {
            for item in store.items where item.analysis == nil {
                await scheduleAnalysis(for: item)
            }
        }
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

    func storageReport() async throws -> TrayStorageReport {
        try await repository.storageReport(at: now())
    }

    func waitForScheduledAnalysis() async {
        await analysisScheduler.waitUntilIdle()
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

    func setSensitivityOverridden(
        _ id: UUID,
        to isOverridden: Bool
    ) async throws -> TrayItem {
        guard let item = try await repository.apply(
            .setSensitivityOverridden(id, isOverridden)
        ).item else {
            throw TrayError.itemNotFound
        }
        return item
    }

    func edit(
        _ id: UUID,
        text: String,
        title: String?,
        note: String?,
        collectionID: UUID? = nil,
        acknowledgingSensitiveContent: Bool = false
    ) async throws -> TrayItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrayError.emptyText
        }
        let edits = TrayItemEdits(
            kind: Self.webURL(from: text) == nil ? .text : .url,
            text: text,
            title: Self.nonBlank(title),
            note: Self.nonBlank(note),
            collectionID: collectionID,
            sensitivity: assessment(for: text)
        )
        if
            let sensitivity = edits.sensitivity,
            !acknowledgingSensitiveContent
        {
            throw TrayError.sensitiveContentRequiresAcknowledgment(
                SensitiveContentReason.ordered(sensitivity.reasons)
            )
        }
        guard let item = try await repository.apply(.edit(id, edits, now())).item else {
            throw TrayError.itemNotFound
        }
        if item.analysis == nil {
            await scheduleAnalysis(for: item)
        }
        return item
    }

    private func scheduleAnalysis(for item: TrayItem) async {
        await analysisScheduler.schedule(itemID: item.id) {
            await analyzeAndPersist(item)
        }
    }

    private func analyzeAndPersist(_ item: TrayItem) async {
        do {
            let assetData: Data?
            let assetTypeIdentifier: String?
            if item.kind == .image, let asset = item.asset {
                let resource = try await repository.resource(for: asset)
                assetData = resource.data
                assetTypeIdentifier = asset.typeIdentifier
            } else {
                assetData = nil
                assetTypeIdentifier = nil
            }
            let result = try await analyzer.analyze(
                ContentAnalysisInput(
                    itemID: item.id,
                    kind: item.kind,
                    text: item.text,
                    assetData: assetData,
                    assetTypeIdentifier: assetTypeIdentifier
                )
            )
            let sensitivity = result.searchableText.flatMap(assessment(for:))
            _ = try await repository.apply(
                .setAnalysis(
                    item.id,
                    sourceKey: item.analysisSourceKey,
                    result,
                    sensitivity
                )
            )
        } catch {
            // Intelligence is best-effort. The durable original remains usable.
        }
    }

    private func assessment(for text: String) -> SensitivityAssessment? {
        let reasons = sensitiveContentClassifier.reasons(in: text)
        return reasons.isEmpty ? nil : SensitivityAssessment(reasons: reasons)
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
