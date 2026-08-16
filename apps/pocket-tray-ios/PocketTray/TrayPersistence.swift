import Foundation

protocol TrayMetadataWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

struct AtomicTrayMetadataWriter: TrayMetadataWriting {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

actor FileTrayRepository: TrayRepository {
    static let appGroupIdentifier = "group.com.pallavk.PocketTray"

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let fileManager: FileManager
    private let assetStore: AssetStore
    private let metadataWriter: any TrayMetadataWriting
    private var recoveredMetadata = false

    init(
        fileURL: URL,
        legacyFileURL: URL? = nil,
        assetDirectoryURL: URL? = nil,
        assetWriter: any AssetDataWriting = AtomicAssetDataWriter(),
        metadataWriter: any TrayMetadataWriting = AtomicTrayMetadataWriter()
    ) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.fileManager = FileManager()
        self.metadataWriter = metadataWriter
        self.assetStore = AssetStore(
            directoryURL: assetDirectoryURL
                ?? fileURL.deletingLastPathComponent().appending(path: "assets"),
            writer: assetWriter
        )
    }

    static func applicationSupport() -> FileTrayRepository {
        let fileManager = FileManager()
        return FileTrayRepository(fileURL: applicationSupportFileURL(using: fileManager))
    }

    static func sharedContainer() throws -> FileTrayRepository {
        let fileManager = FileManager()
        guard let baseURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw TrayPersistenceError.appGroupUnavailable
        }
        return FileTrayRepository(
            fileURL: baseURL
                .appending(path: "PocketTray", directoryHint: .isDirectory)
                .appending(path: "tray.json"),
            legacyFileURL: applicationSupportFileURL(using: fileManager)
        )
    }

    private static func applicationSupportFileURL(using fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL
            .appending(path: "PocketTray", directoryHint: .isDirectory)
            .appending(path: "tray.json")
    }

    func apply(_ mutation: TrayMutation) throws -> TrayMutationResult {
        try Task.checkCancellation()
        var createdAsset: TrayAsset?
        do {
            if case let .capture(_, assetWrite: assetWrite?) = mutation {
                if try assetStore.persist(assetWrite) {
                    createdAsset = assetWrite.asset
                }
                try Task.checkCancellation()
            }
            return try updateStore { store in
                store.apply(mutation)
            }
        } catch {
            if let createdAsset {
                try? assetStore.remove(createdAsset)
            }
            throw Self.actionableWriteError(error)
        }
    }

    func resource(for asset: TrayAsset) throws -> TrayAssetResource {
        try assetStore.resource(for: asset)
    }

    func store(at date: Date) throws -> TrayStore {
        try updateStore { store in
            store.items.maintainLifecycle(at: date)
            return store
        }
    }

    func storageReport(at date: Date) throws -> TrayStorageReport {
        try migrateLegacyFileIfNeeded()
        let store = try loadStore(at: fileURL)
        try? assetStore.removeUnreferencedAssets(keeping: store.items.compactMap(\.asset))
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
            recoveredMetadata: recoveredMetadata
        )
    }

    private func loadStore(at url: URL) throws -> TrayStore {
        let backupURL = backupURL(for: url)
        guard fileManager.fileExists(atPath: url.path) else {
            if fileManager.fileExists(atPath: backupURL.path) {
                do {
                    let recovered = try decodeStore(Data(contentsOf: backupURL))
                    recoveredMetadata = true
                    return recovered
                } catch {
                    throw TrayPersistenceError.metadataCorrupt
                }
            }
            return .empty
        }
        do {
            return try decodeStore(Data(contentsOf: url))
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw TrayPersistenceError.metadataCorrupt
            }
            do {
                let recovered = try decodeStore(Data(contentsOf: backupURL))
                recoveredMetadata = true
                return recovered
            } catch {
                throw TrayPersistenceError.metadataCorrupt
            }
        }
    }

    private func decodeStore(_ data: Data) throws -> TrayStore {
        if let store = try? JSONDecoder().decode(TrayStore.self, from: data) {
            return store
        }
        return TrayStore(items: try JSONDecoder().decode([TrayItem].self, from: data))
    }

    private func updateStore<Value: Sendable>(
        _ operation: @Sendable (inout TrayStore) throws -> Value
    ) throws -> Value {
        try migrateLegacyFileIfNeeded()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try coordinateWriting { coordinatedURL in
            var store = try loadStore(at: coordinatedURL)
            let value = try operation(&store)
            let data = try JSONEncoder().encode(store)
            try metadataWriter.write(data, to: coordinatedURL)
            try? metadataWriter.write(data, to: backupURL(for: coordinatedURL))
            try? assetStore.removeUnreferencedAssets(keeping: store.items.compactMap(\.asset))
            return value
        }
    }

    private func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private func migrateLegacyFileIfNeeded() throws {
        guard let legacyFileURL else { return }

        if
            !fileManager.fileExists(atPath: fileURL.path),
            fileManager.fileExists(atPath: legacyFileURL.path)
        {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: legacyFileURL, to: fileURL)
        }
        try migrateLegacyAssets(from: legacyFileURL)
    }

    private func migrateLegacyAssets(from legacyFileURL: URL) throws {
        let legacyAssetsURL = legacyFileURL.deletingLastPathComponent()
            .appending(path: "assets", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: legacyAssetsURL.path) else { return }
        try fileManager.createDirectory(
            at: assetStore.directoryURL,
            withIntermediateDirectories: true
        )
        for sourceURL in try fileManager.contentsOfDirectory(
            at: legacyAssetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            guard try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let destinationURL = assetStore.directoryURL.appending(path: sourceURL.lastPathComponent)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    throw error
                }
            }
        }
    }

    private func coordinateWriting<Value>(
        _ operation: (URL) throws -> Value
    ) throws -> Value {
        var coordinationError: NSError?
        var operationResult: Result<Value, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result { try operation(coordinatedURL) }
        }
        if let operationResult {
            return try operationResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw TrayPersistenceError.coordinationFailed
    }

    private static func actionableWriteError(_ error: Error) -> Error {
        if let persistenceError = error as? TrayPersistenceError {
            return persistenceError
        }
        if let cocoaError = error as? CocoaError,
           cocoaError.code == .fileWriteOutOfSpace {
            return TrayPersistenceError.insufficientStorage
        }
        if error is CocoaError {
            return TrayPersistenceError.writeFailed
        }
        return error
    }
}

enum TrayPersistenceError: Error, Equatable, LocalizedError {
    case appGroupUnavailable
    case coordinationFailed
    case insufficientStorage
    case metadataCorrupt
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Pocket Tray's shared storage is unavailable."
        case .coordinationFailed:
            "Pocket Tray couldn't coordinate access to shared storage."
        case .insufficientStorage:
            "Pocket Tray couldn't save this object. Free up space on your iPhone, then try again."
        case .metadataCorrupt:
            "Pocket Tray's saved index is damaged and no usable backup is available. Your original files were not deleted."
        case .writeFailed:
            "Pocket Tray couldn't finish writing this object. Check available storage and try again; no partial capture was kept."
        }
    }
}

actor UnavailableTrayRepository: TrayRepository {
    func apply(_ mutation: TrayMutation) throws -> TrayMutationResult {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func store(at date: Date) throws -> TrayStore {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func resource(for asset: TrayAsset) throws -> TrayAssetResource {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func storageReport(at date: Date) throws -> TrayStorageReport {
        throw TrayPersistenceError.appGroupUnavailable
    }
}
