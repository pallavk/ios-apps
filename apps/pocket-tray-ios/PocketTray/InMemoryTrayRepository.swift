import Foundation

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

    func storageReport(at date: Date) throws -> TrayStorageReport {
        store.items.maintainLifecycle(at: date)
        let assets = Dictionary(
            store.items.compactMap(\.asset).map { ($0.digest, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        var assetBytes: Int64 = 0
        var unavailableAssetCount = 0
        for asset in assets {
            do {
                assetBytes += try assetStore.storedByteCount(for: asset)
            } catch {
                unavailableAssetCount += 1
            }
        }
        return TrayStorageReport(
            metadataBytes: Int64(try JSONEncoder().encode(store).count),
            assetBytes: assetBytes,
            unavailableAssetCount: unavailableAssetCount,
            recoveredMetadata: false
        )
    }
}
