import Foundation

actor FileTrayRepository: TrayRepository {
    static let appGroupIdentifier = "group.com.pallavk.PocketTray"

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let fileManager: FileManager
    private let assetStore: AssetStore

    init(
        fileURL: URL,
        legacyFileURL: URL? = nil,
        assetDirectoryURL: URL? = nil,
        assetWriter: any AssetDataWriting = AtomicAssetDataWriter()
    ) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.fileManager = FileManager()
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
        if case let .capture(_, assetWrite: assetWrite?) = mutation {
            try assetStore.persist(assetWrite)
        }
        return try updateStore { store in
            store.apply(mutation)
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

    private func loadStore(at url: URL) throws -> TrayStore {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
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
            try JSONEncoder().encode(store).write(to: coordinatedURL, options: .atomic)
            return value
        }
    }

    private func migrateLegacyFileIfNeeded() throws {
        guard
            !fileManager.fileExists(atPath: fileURL.path),
            let legacyFileURL,
            fileManager.fileExists(atPath: legacyFileURL.path)
        else {
            return
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: legacyFileURL, to: fileURL)
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
        if let coordinationError {
            throw coordinationError
        }
        guard let operationResult else {
            throw TrayPersistenceError.coordinationFailed
        }
        return try operationResult.get()
    }
}

enum TrayPersistenceError: Error, LocalizedError {
    case appGroupUnavailable
    case coordinationFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Pocket Tray's shared storage is unavailable."
        case .coordinationFailed:
            "Pocket Tray couldn't coordinate access to shared storage."
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
}
