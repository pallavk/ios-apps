import Foundation

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
    private(set) var analysis: ContentAnalysis?
    private(set) var sensitivity: SensitivityAssessment?
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
        analysis: ContentAnalysis? = nil,
        sensitivity: SensitivityAssessment? = nil,
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
        self.analysis = analysis
        self.sensitivity = sensitivity
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
        case analysis
        case sensitivity
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
        analysis = try container.decodeIfPresent(ContentAnalysis.self, forKey: .analysis)
        sensitivity = try container.decodeIfPresent(SensitivityAssessment.self, forKey: .sensitivity)
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
        try container.encodeIfPresent(analysis, forKey: .analysis)
        try container.encodeIfPresent(sensitivity, forKey: .sensitivity)
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
        if updated.sensitivity == nil {
            updated.sensitivity = candidate.sensitivity
        }
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
            if updated.kind != edits.kind || updated.text != edits.text {
                updated.analysis = nil
                updated.sensitivity = edits.sensitivity
            }
            updated.kind = edits.kind
            updated.text = edits.text
            updated.deduplicationKeys.insert(edits.text)
        }
        updated.title = edits.title
        updated.note = edits.note
        updated.collectionID = edits.collectionID
        return updated
    }

    func settingAnalysis(
        _ analysis: ContentAnalysis,
        sensitivity: SensitivityAssessment?
    ) -> TrayItem {
        var updated = self
        updated.analysis = analysis
        if updated.sensitivity?.isOverridden != true, let sensitivity {
            updated.sensitivity = sensitivity
        }
        return updated
    }

    func settingSensitivityOverridden(_ isOverridden: Bool) -> TrayItem? {
        guard let sensitivity else { return nil }
        var updated = self
        updated.sensitivity = sensitivity.settingOverridden(isOverridden)
        return updated
    }

    var protectsSensitivePreview: Bool {
        sensitivity != nil && sensitivity?.isOverridden == false
    }

    var analysisSourceKey: String {
        "\(kind.rawValue)\u{0}\(text)\u{0}\(asset?.digest ?? "")"
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
    let sensitivity: SensitivityAssessment?

    init(
        kind: TrayItemKind,
        text: String,
        title: String?,
        note: String?,
        collectionID: UUID?,
        sensitivity: SensitivityAssessment? = nil
    ) {
        self.kind = kind
        self.text = text
        self.title = title
        self.note = note
        self.collectionID = collectionID
        self.sensitivity = sensitivity
    }
}

struct TrayCollection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    private(set) var name: String
    let createdAt: Date

    func renamed(to name: String) -> TrayCollection {
        TrayCollection(id: id, name: name, createdAt: createdAt)
    }
}
