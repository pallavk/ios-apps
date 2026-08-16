import Foundation
import UIKit
import UniformTypeIdentifiers

private final class ProviderProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var isCancelled = false

    func install(_ progress: Progress) {
        lock.lock()
        self.progress = progress
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let progress = progress
        lock.unlock()
        progress?.cancel()
    }

    var cancelled: Bool {
        lock.lock()
        let value = isCancelled
        lock.unlock()
        return value
    }
}

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
        let data = try await loadBoundedFileRepresentation(forTypeIdentifier: typeIdentifier)
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
        let data = try await loadBoundedFileRepresentation(
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

    private func loadBoundedFileRepresentation(
        forTypeIdentifier typeIdentifier: String
    ) async throws -> Data {
        let progressBox = ProviderProgressBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = provider.loadFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw ShareCaptureError.unreadable }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        if let fileSize = values.fileSize,
                           fileSize > ImageAssetFactory.maximumByteCount {
                            throw TrayAssetError.tooLarge(
                                maximumBytes: ImageAssetFactory.maximumByteCount
                            )
                        }
                        let data = try self.readBoundedData(
                            from: url,
                            progressBox: progressBox
                        )
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                progressBox.install(progress)
            }
        } onCancel: {
            progressBox.cancel()
        }
    }

    private func readBoundedData(
        from url: URL,
        progressBox: ProviderProgressBox
    ) throws -> Data {
        let maximum = ImageAssetFactory.maximumByteCount
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(maximum + 1)
        while data.count <= maximum {
            if progressBox.cancelled { throw CancellationError() }
            let remaining = maximum + 1 - data.count
            guard
                let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                !chunk.isEmpty
            else {
                return data
            }
            data.append(chunk)
        }
        throw TrayAssetError.tooLarge(maximumBytes: maximum)
    }
}
