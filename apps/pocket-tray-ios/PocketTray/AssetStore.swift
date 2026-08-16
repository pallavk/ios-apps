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
        let exportURL = try exportURL(for: asset, storedAt: fileURL, data: data)
        return TrayAssetResource(
            asset: asset,
            url: fileURL,
            exportURL: exportURL,
            data: data
        )
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
            try ImageAssetFactory.validate(temporaryData, as: asset)
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
        return (try? ImageAssetFactory.validate(data, as: asset)) != nil
    }
}
