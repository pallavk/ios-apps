import Foundation

struct TrayStore: Codable, Equatable, Sendable {
    static let empty = TrayStore()

    var items: [TrayItem]
    var collections: [TrayCollection]

    init(items: [TrayItem] = [], collections: [TrayCollection] = []) {
        self.items = items
        self.collections = collections
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
        case let .restoreStateFromUndo(original):
            .item(items.restoreStateFromUndo(original))
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
        case let .setAnalysis(id, sourceKey, analysis, sensitivity):
            .item(setAnalysis(
                analysis,
                sensitivity: sensitivity,
                for: id,
                sourceKey: sourceKey
            ))
        case let .setSensitivityOverridden(id, isOverridden):
            .item(setSensitivityOverridden(isOverridden, for: id))
        }
    }

    private mutating func setAnalysis(
        _ analysis: ContentAnalysis,
        sensitivity: SensitivityAssessment?,
        for id: UUID,
        sourceKey: String
    ) -> TrayItem? {
        guard let index = items.firstIndex(where: {
            $0.id == id && $0.analysisSourceKey == sourceKey
        }) else { return nil }
        let updated = items[index].settingAnalysis(analysis, sensitivity: sensitivity)
        items[index] = updated
        return updated
    }

    private mutating func setSensitivityOverridden(
        _ isOverridden: Bool,
        for id: UUID
    ) -> TrayItem? {
        guard
            let index = items.firstIndex(where: { $0.id == id }),
            let updated = items[index].settingSensitivityOverridden(isOverridden)
        else { return nil }
        items[index] = updated
        return updated
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

    mutating func restoreStateFromUndo(_ original: TrayItem) -> TrayItem? {
        guard let index = firstIndex(where: { $0.id == original.id }) else { return nil }
        self[index] = original
        return original
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
