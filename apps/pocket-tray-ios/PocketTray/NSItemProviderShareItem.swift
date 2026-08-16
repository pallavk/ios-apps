import UIKit
import UniformTypeIdentifiers

final class NSItemProviderShareItem: @unchecked Sendable, ShareItemProviding {
    private let provider: NSItemProvider

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    var canLoadImage: Bool { imageTypeIdentifier != nil }

    var canLoadPDF: Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
    }

    var canLoadURL: Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }

    var canLoadText: Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
    }

    func loadImage() async throws -> ImagePayload {
        guard let typeIdentifier = imageTypeIdentifier else {
            throw ShareCaptureError.unsupported
        }
        let data = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
        return ImagePayload(
            data: data,
            typeIdentifier: typeIdentifier,
            filename: provider.suggestedName
        )
    }

    func loadPDF() async throws -> PDFPayload {
        guard canLoadPDF else {
            throw ShareCaptureError.unsupported
        }
        let data = try await loadDataRepresentation(
            forTypeIdentifier: UTType.pdf.identifier
        )
        return PDFPayload(
            data: data,
            typeIdentifier: UTType.pdf.identifier,
            filename: provider.suggestedName
        )
    }

    func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
    }

    func loadText() async throws -> String {
        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : UTType.text.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let attributedString = item as? NSAttributedString {
                    continuation.resume(returning: attributedString.string)
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
    }

    private var imageTypeIdentifier: String? {
        let imageIdentifiers = provider.registeredTypeIdentifiers.filter { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
        return imageIdentifiers.first { identifier in
            identifier != UTType.image.identifier
                && UTType(identifier)?.preferredFilenameExtension != nil
        } ?? imageIdentifiers.first
    }

    private func loadDataRepresentation(forTypeIdentifier typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ShareCaptureError.unreadable)
                }
            }
        }
    }
}
