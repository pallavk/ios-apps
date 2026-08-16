import Foundation
import UniformTypeIdentifiers

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

    @discardableResult
    func persist(_ write: TrayAssetWrite) throws -> Bool {
        try validatePathComponents(of: write.asset)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let finalURL = url(for: write.asset)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            if (try? validatedData(for: write.asset)) != nil {
                return false
            }
            try FileManager.default.removeItem(at: finalURL)
        }

        do {
            try writer.write(write.data, to: finalURL)
        } catch {
            if FileManager.default.fileExists(atPath: finalURL.path),
               (try? validatedData(for: write.asset)) != nil {
                return false
            }
            throw error
        }
        do {
            _ = try validatedData(for: write.asset)
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
        return true
    }

    func resource(for asset: TrayAsset) throws -> TrayAssetResource {
        try validatePathComponents(of: asset)
        let fileURL = url(for: asset)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TrayAssetError.missing
        }
        let data = try validatedData(for: asset)
        let exportURL = try exportURL(for: asset, storedAt: fileURL, data: data)
        return TrayAssetResource(
            asset: asset,
            url: fileURL,
            exportURL: exportURL,
            data: data
        )
    }

    func remove(_ asset: TrayAsset) throws {
        try validatePathComponents(of: asset)
        let fileURL = url(for: asset)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        let exportDirectory = directoryURL
            .appending(path: ".exports", directoryHint: .isDirectory)
            .appending(path: asset.digest, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: exportDirectory.path) {
            try FileManager.default.removeItem(at: exportDirectory)
        }
    }

    func storedByteCount(for asset: TrayAsset) throws -> Int64 {
        Int64(try validatedData(for: asset).count)
    }

    func removeUnreferencedAssets(keeping assets: [TrayAsset]) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        let keptFilenames = Set(assets.map { "\($0.digest).\($0.fileExtension)" })
        for url in try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, !keptFilenames.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }

        let exportsURL = directoryURL.appending(path: ".exports", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: exportsURL.path) else { return }
        let keptDigests = Set(assets.map(\.digest))
        for url in try FileManager.default.contentsOfDirectory(
            at: exportsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) where !keptDigests.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
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

    private func validatedData(for asset: TrayAsset) throws -> Data {
        let fileURL = url(for: asset)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TrayAssetError.missing
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try TrayAssetValidator.validate(data, as: asset)
        return data
    }

    private func exportURL(
        for asset: TrayAsset,
        storedAt fileURL: URL,
        data: Data
    ) throws -> URL {
        guard let originalFilename = asset.originalFilename else {
            return fileURL
        }
        let sanitizedFilename = URL(fileURLWithPath: originalFilename).lastPathComponent
        guard !sanitizedFilename.isEmpty, sanitizedFilename != "." else {
            return fileURL
        }
        let originalExtension = URL(fileURLWithPath: sanitizedFilename).pathExtension
        let originalType = UTType(filenameExtension: originalExtension)
        let filename: String
        if originalType?.identifier == asset.typeIdentifier {
            filename = sanitizedFilename
        } else {
            let baseName = URL(fileURLWithPath: sanitizedFilename)
                .deletingPathExtension()
                .lastPathComponent
            filename = "\(baseName.isEmpty ? asset.digest : baseName).\(asset.fileExtension)"
        }

        let exportDirectory = directoryURL
            .appending(path: ".exports", directoryHint: .isDirectory)
            .appending(path: asset.digest, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        let exportURL = exportDirectory.appending(path: filename)
        if validExportExists(at: exportURL, for: asset) {
            return exportURL
        }

        if FileManager.default.fileExists(atPath: exportURL.path) {
            do {
                try FileManager.default.removeItem(at: exportURL)
            } catch {
                if validExportExists(at: exportURL, for: asset) {
                    return exportURL
                }
                if FileManager.default.fileExists(atPath: exportURL.path) {
                    throw error
                }
            }
        }

        let temporaryURL = exportDirectory.appending(
            path: ".\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            let temporaryData = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            try TrayAssetValidator.validate(temporaryData, as: asset)
            try FileManager.default.moveItem(at: temporaryURL, to: exportURL)
        } catch {
            if validExportExists(at: exportURL, for: asset) {
                return exportURL
            }
            throw error
        }
        guard validExportExists(at: exportURL, for: asset) else {
            throw TrayAssetError.corrupt
        }
        return exportURL
    }

    private func validExportExists(at url: URL, for asset: TrayAsset) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }
        return (try? TrayAssetValidator.validate(data, as: asset)) != nil
    }
}
