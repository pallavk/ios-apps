import Foundation

enum ShareCaptureError: Error, Equatable, LocalizedError {
    case unsupported
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "Pocket Tray supports shared text and web links."
        case .unreadable:
            "Pocket Tray couldn't read the shared item."
        }
    }
}

protocol ShareItemProviding: Sendable {
    var canLoadURL: Bool { get }
    var canLoadText: Bool { get }
    func loadURL() async throws -> URL
    func loadText() async throws -> String
}

struct ShareCapture: Sendable {
    private let tray: Tray

    init(tray: Tray) {
        self.tray = tray
    }

    func capture(_ provider: any ShareItemProviding) async throws -> TrayItem {
        let content: CaptureContent
        do {
            if provider.canLoadURL {
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

        return try await tray.capture(content)
    }
}
