import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImagePayload: Equatable, Sendable {
    let data: Data
    let typeIdentifier: String
    let filename: String?
}

struct TrayAsset: Codable, Equatable, Sendable {
    let digest: String
    let byteCount: Int
    let typeIdentifier: String
    let fileExtension: String
    let originalFilename: String?
}

struct TrayAssetWrite: Equatable, Sendable {
    let asset: TrayAsset
    let data: Data
}

struct TrayAssetResource: Equatable, Sendable {
    let asset: TrayAsset
    let url: URL
    let exportURL: URL
    let data: Data
}

enum TrayAssetError: Error, Equatable, LocalizedError {
    case corrupt
    case invalidImage
    case invalidPDF
    case missing
    case tooLarge(maximumBytes: Int)
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .corrupt:
            String(localized: "The original file is damaged and can't be opened. Re-copy and save it again, or delete this object.")
        case .invalidImage:
            String(localized: "Pocket Tray couldn't read that image.")
        case .invalidPDF:
            String(localized: "Pocket Tray couldn't read that PDF.")
        case .missing:
            String(localized: "The original file is missing. Re-copy and save it again, or delete this object.")
        case let .tooLarge(maximumBytes):
            String(localized: "That file is larger than \(maximumBytes / 1_000_000) MB.")
        case .unsupportedType:
            String(localized: "Pocket Tray doesn't support that file format.")
        }
    }
}

enum TrayAssetValidator {
    static func validate(_ data: Data, as asset: TrayAsset) throws {
        if UTType(asset.typeIdentifier)?.conforms(to: .pdf) == true {
            try PDFAssetFactory.validate(data, as: asset)
        } else {
            try ImageAssetFactory.validate(data, as: asset)
        }
    }
}

enum ImageAssetFactory {
    static let maximumByteCount = 25_000_000

    static func makeWrite(from payload: ImagePayload) throws -> TrayAssetWrite {
        guard payload.data.count <= maximumByteCount else {
            throw TrayAssetError.tooLarge(maximumBytes: maximumByteCount)
        }
        guard
            let type = UTType(payload.typeIdentifier),
            type.conforms(to: .image)
        else {
            throw TrayAssetError.unsupportedType
        }
        guard let decodedTypeIdentifier = decodedTypeIdentifier(for: payload.data) else {
            throw TrayAssetError.invalidImage
        }
        let decodedType = UTType(decodedTypeIdentifier) ?? type

        let asset = TrayAsset(
            digest: digest(of: payload.data),
            byteCount: payload.data.count,
            typeIdentifier: decodedType.identifier,
            fileExtension: decodedType.preferredFilenameExtension?.lowercased() ?? "img",
            originalFilename: payload.filename
        )
        return TrayAssetWrite(asset: asset, data: payload.data)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ data: Data, as asset: TrayAsset) throws {
        guard
            data.count == asset.byteCount,
            digest(of: data) == asset.digest,
            decodedTypeIdentifier(for: data) != nil
        else {
            throw TrayAssetError.corrupt
        }
    }

    private static func decodedTypeIdentifier(for data: Data) -> String? {
        guard
            !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) != nil else {
            return nil
        }
        return CGImageSourceGetType(source) as String?
    }
}
