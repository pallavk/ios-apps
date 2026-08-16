import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct PDFPayload: Equatable, Sendable {
    let data: Data
    let typeIdentifier: String
    let filename: String?
}

enum PDFAssetFactory {
    static let maximumByteCount = ImageAssetFactory.maximumByteCount

    static func makeWrite(from payload: PDFPayload) throws -> TrayAssetWrite {
        guard payload.data.count <= maximumByteCount else {
            throw TrayAssetError.tooLarge(maximumBytes: maximumByteCount)
        }
        guard UTType(payload.typeIdentifier)?.conforms(to: .pdf) == true else {
            throw TrayAssetError.unsupportedType
        }
        guard isReadablePDF(payload.data) else {
            throw TrayAssetError.invalidPDF
        }
        return TrayAssetWrite(
            asset: TrayAsset(
                digest: ImageAssetFactory.digest(of: payload.data),
                byteCount: payload.data.count,
                typeIdentifier: UTType.pdf.identifier,
                fileExtension: "pdf",
                originalFilename: payload.filename
            ),
            data: payload.data
        )
    }

    static func validate(_ data: Data, as asset: TrayAsset) throws {
        guard
            data.count == asset.byteCount,
            ImageAssetFactory.digest(of: data) == asset.digest,
            asset.typeIdentifier == UTType.pdf.identifier,
            isReadablePDF(data)
        else {
            throw TrayAssetError.corrupt
        }
    }

    private static func isReadablePDF(_ data: Data) -> Bool {
        guard
            !data.isEmpty,
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider),
            document.numberOfPages > 0
        else {
            return false
        }
        return !document.isEncrypted || document.isUnlocked
    }
}
