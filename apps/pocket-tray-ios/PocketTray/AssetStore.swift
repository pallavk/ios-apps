import Foundation

protocol AssetDataWriting: Sendable {
    func write(_ data: Data, to finalURL: URL) throws
}

struct AnyAssetDataWriter: AssetDataWriting {
    private let operation: @Sendable (Data, URL) throws -> Void

    init<Writer: AssetDataWriting>(_ writer: Writer) {
        operation = writer.write
    }

    func write(_ data: Data, to finalURL: URL) throws {
        try operation(data, finalURL)
    }
}

struct AtomicAssetDataWriter: AssetDataWriting {
    func write(_ data: Data, to finalURL: URL) throws {
        let temporaryURL = finalURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }
}

struct AssetStore: Sendable {
    let directoryURL: URL
    let writer: any AssetDataWriting

    init(
        directoryURL: URL,
        writer: any AssetDataWriting = AtomicAssetDataWriter()
    ) {
        self.directoryURL = directoryURL
        self.writer = writer
    }

    func persist(_ write: TrayAssetWrite) throws {
        try validatePathComponents(of: write.asset)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let finalURL = url(for: write.asset)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try resource(for: write.asset)
            return
        }

        do {
            try writer.write(write.data, to: finalURL)
        } catch {
            if FileManager.default.fileExists(atPath: finalURL.path),
               (try? resource(for: write.asset)) != nil {
                return
            }
            throw error
        }
        _ = try resource(for: write.asset)
    }

    func resource(for asset: TrayAsset) throws -> TrayAssetResource {
        try validatePathComponents(of: asset)
        let fileURL = url(for: asset)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TrayAssetError.missing
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try ImageAssetFactory.validate(data, as: asset)
        return TrayAssetResource(asset: asset, url: fileURL, data: data)
    }

    func url(for asset: TrayAsset) -> URL {
        directoryURL.appending(path: "\(asset.digest).\(asset.fileExtension)")
    }

    private func validatePathComponents(of asset: TrayAsset) throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard
            asset.digest.count == 64,
            asset.digest.unicodeScalars.allSatisfy(hexadecimal.contains),
            !asset.fileExtension.isEmpty,
            asset.fileExtension.unicodeScalars.allSatisfy(
                CharacterSet.alphanumerics.contains
            )
        else {
            throw TrayAssetError.corrupt
        }
    }
}
