import Foundation

actor FileTrayRepository: TrayRepository {
    static let appGroupIdentifier = "group.com.pallavk.PocketTray"

    private let fileURL: URL
    private let legacyFileURL: URL?
    private let fileManager: FileManager

    init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.fileManager = FileManager()
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

    func save(_ item: TrayItem) throws -> TrayItem {
        try updateItems { items in
            items.saveCapture(item)
        }
    }

    func setPinned(_ id: UUID, to isPinned: Bool, at date: Date) throws -> TrayItem? {
        try updateItems { items in
            items.setPinned(id, to: isPinned, at: date)
        }
    }

    func moveToTrash(_ id: UUID, at date: Date) throws -> TrayItem? {
        try updateItems { items in
            items.moveToTrash(id, at: date)
        }
    }

    func restore(_ id: UUID, at date: Date) throws -> TrayItem? {
        try updateItems { items in
            items.restore(id, at: date)
        }
    }

    func deletePermanently(_ id: UUID) throws -> Bool {
        try updateItems { items in
            items.deletePermanently(id)
        }
    }

    func items(at date: Date) throws -> [TrayItem] {
        try updateItems { items in
            items.maintainLifecycle(at: date)
            return items
        }
    }

    private func loadItems(at url: URL) throws -> [TrayItem] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try JSONDecoder().decode([TrayItem].self, from: Data(contentsOf: url))
    }

    private func updateItems<Value: Sendable>(
        _ operation: @Sendable (inout [TrayItem]) throws -> Value
    ) throws -> Value {
        try migrateLegacyFileIfNeeded()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try coordinateWriting { coordinatedURL in
            var items = try loadItems(at: coordinatedURL)
            let value = try operation(&items)
            try JSONEncoder().encode(items).write(to: coordinatedURL, options: .atomic)
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
    func save(_ item: TrayItem) throws -> TrayItem {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func items(at date: Date) throws -> [TrayItem] {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func setPinned(_ id: UUID, to isPinned: Bool, at date: Date) throws -> TrayItem? {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func moveToTrash(_ id: UUID, at date: Date) throws -> TrayItem? {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func restore(_ id: UUID, at date: Date) throws -> TrayItem? {
        throw TrayPersistenceError.appGroupUnavailable
    }

    func deletePermanently(_ id: UUID) throws -> Bool {
        throw TrayPersistenceError.appGroupUnavailable
    }
}
