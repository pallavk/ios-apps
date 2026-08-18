import Foundation

enum TrayMutation: Sendable {
    case capture(TrayItem, assetWrite: TrayAssetWrite?)
    case setPinned(UUID, Bool, Date)
    case moveToTrash(UUID, Date)
    case restore(UUID, Date)
    case restoreStateFromUndo(TrayItem)
    case deletePermanently(UUID)
    case edit(UUID, TrayItemEdits, Date)
    case createCollection(TrayCollection)
    case assign(UUID, UUID?, Date)
    case renameCollection(UUID, String)
    case deleteCollection(UUID)
    case deleteCollectionForUndo(UUID)
    case restoreDeletedCollection(DeletedCollection)
    case reorderCollections([UUID])
    case setAnalysis(UUID, sourceKey: String, ContentAnalysis, SensitivityAssessment?)
    case setSensitivityOverridden(UUID, Bool)
}

enum TrayMutationResult: Sendable {
    case item(TrayItem?)
    case collection(TrayCollection?)
    case deletedCollection(DeletedCollection?)
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

    var deletedCollection: DeletedCollection? {
        get throws {
            guard case let .deletedCollection(deletion) = self else {
                throw TrayRepositoryContractError.unexpectedMutationResult
            }
            return deletion
        }
    }
}

struct DeletedCollection: Equatable, Sendable {
    let collection: TrayCollection
    let assignedItemIDs: Set<UUID>
    let index: Int
}

private enum TrayRepositoryContractError: Error {
    case unexpectedMutationResult
}

protocol TrayRepository: Sendable {
    func apply(_ mutation: TrayMutation) async throws -> TrayMutationResult
    func resource(for asset: TrayAsset) async throws -> TrayAssetResource
    func store(at date: Date) async throws -> TrayStore
    func storageReport(at date: Date) async throws -> TrayStorageReport
}

struct TrayStorageReport: Equatable, Sendable {
    static let warningThresholdBytes: Int64 = 500_000_000

    let metadataBytes: Int64
    let assetBytes: Int64
    let unavailableAssetCount: Int
    let recoveredMetadata: Bool

    var totalBytes: Int64 { metadataBytes + assetBytes }
    var exceedsWarningThreshold: Bool { totalBytes > Self.warningThresholdBytes }
}
