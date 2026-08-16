import Foundation

actor FileTrayRepository: TrayRepository {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.fileManager = FileManager()
    }

    static func applicationSupport() -> FileTrayRepository {
        let fileManager = FileManager()
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return FileTrayRepository(
            fileURL: baseURL
                .appending(path: "PocketTray", directoryHint: .isDirectory)
                .appending(path: "tray.json")
        )
    }

    func save(_ item: TrayItem) throws {
        var items = try loadItems()
        items.append(item)

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    func recent() throws -> [TrayItem] {
        try loadItems().newestFirst()
    }

    private func loadItems() throws -> [TrayItem] {
        guard fileManager.fileExists(atPath: fileURL.path()) else {
            return []
        }
        return try JSONDecoder().decode([TrayItem].self, from: Data(contentsOf: fileURL))
    }
}
