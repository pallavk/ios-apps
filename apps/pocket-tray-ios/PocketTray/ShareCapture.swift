import Foundation

enum ShareCaptureError: Error, Equatable, LocalizedError {
    case unsupported
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "Pocket Tray supports shared images, text, and web links."
        case .unreadable:
            "Pocket Tray couldn't read the shared item."
        }
    }
}

protocol ShareItemProviding: Sendable {
    var canLoadImage: Bool { get }
    var canLoadPDF: Bool { get }
    var canLoadURL: Bool { get }
    var canLoadText: Bool { get }
    func loadImage() async throws -> ImagePayload
    func loadPDF() async throws -> PDFPayload
    func loadURL() async throws -> URL
    func loadText() async throws -> String
}

extension ShareItemProviding {
    var canLoadImage: Bool { false }
    var canLoadPDF: Bool { false }

    func loadImage() async throws -> ImagePayload {
        throw ShareCaptureError.unsupported
    }

    func loadPDF() async throws -> PDFPayload {
        throw ShareCaptureError.unsupported
    }
}

enum ShareCaptureRejection: Equatable, Sendable {
    case oversized
    case storage
    case unreadable
    case unsupported
}

struct ShareCaptureBatchResult: Equatable, Sendable {
    let accepted: [TrayItem]
    let rejected: [ShareCaptureRejection]
}

struct ShareCapture: Sendable {
    private let tray: Tray

    init(tray: Tray) {
        self.tray = tray
    }

    func capture(
        _ provider: any ShareItemProviding,
        willCommit: @MainActor @Sendable () -> Void = {}
    ) async throws -> TrayItem {
        let content: CaptureContent
        do {
            if provider.canLoadPDF {
                content = .pdf(try await provider.loadPDF())
            } else if provider.canLoadImage {
                content = .image(try await provider.loadImage())
            } else if provider.canLoadURL {
                content = .url(try await provider.loadURL())
            } else if provider.canLoadText {
                content = .text(try await provider.loadText())
            } else {
                throw ShareCaptureError.unsupported
            }
        } catch let error as ShareCaptureError {
            throw error
        } catch {
            throw ShareCaptureError.unreadable
        }

        try Task.checkCancellation()
        await willCommit()
        return try await tray.capture(content)
    }

    func captureAll(
        _ providers: [any ShareItemProviding],
        willCommit: @MainActor @Sendable () -> Void = {}
    ) async throws -> ShareCaptureBatchResult {
        var accepted: [TrayItem] = []
        var rejected: [ShareCaptureRejection] = []
        for provider in providers {
            try Task.checkCancellation()
            do {
                accepted.append(
                    try await capture(provider, willCommit: willCommit)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TrayAssetError {
                if case .tooLarge = error {
                    rejected.append(.oversized)
                } else {
                    rejected.append(.unreadable)
                }
            } catch let error as ShareCaptureError {
                rejected.append(error == .unsupported ? .unsupported : .unreadable)
            } catch {
                rejected.append(.storage)
            }
        }
        return ShareCaptureBatchResult(accepted: accepted, rejected: rejected)
    }
}
