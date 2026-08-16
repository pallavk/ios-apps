import ImageIO
import SwiftUI
import UIKit

struct LoadedTrayImage: @unchecked Sendable {
    let image: UIImage
    let originalURL: URL
}

private actor TrayImageLoadGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = limit
    }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum TrayImageLoader {
    private static let loadGate = TrayImageLoadGate(limit: 2)

    static func thumbnail(
        for item: TrayItem,
        tray: Tray,
        maxPixelSize: Int
    ) async throws -> LoadedTrayImage {
        try await loadGate.withPermit {
            let resource = try await tray.assetResource(for: item)
            try Task.checkCancellation()
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard
                let source = CGImageSourceCreateWithData(resource.data as CFData, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                )
            else {
                throw TrayAssetError.corrupt
            }
            try Task.checkCancellation()
            return LoadedTrayImage(
                image: UIImage(cgImage: thumbnail),
                originalURL: resource.exportURL
            )
        }
    }
}

struct TrayImageRow: View {
    let item: TrayItem
    let collectionName: String?
    let tray: Tray

    var body: some View {
        HStack(spacing: 12) {
            TrayImageThumbnail(item: item, tray: tray, maxPixelSize: 160)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.text)
                    .font(.headline)
                    .lineLimit(2)

                if item.title != nil {
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let note = item.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let collectionName {
                    Label(collectionName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                lifecycleLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var lifecycleLabel: some View {
        if let trashedAt = item.trashedAt {
            Text("Deleted \(trashedAt, format: .relative(presentation: .named))")
        } else if item.isPinned {
            Text("Does not expire")
        } else if let expiresAt = item.expiresAt {
            Text("Expires \(expiresAt, format: .relative(presentation: .named))")
        } else {
            Text(item.capturedAt, format: .relative(presentation: .named))
        }
    }
}

struct TrayImageDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let item: TrayItem
    let tray: Tray

    @State private var loaded: LoadedTrayImage?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    ScrollView {
                        Image(uiImage: loaded.image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Image unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Loading image…")
                }
            }
            .navigationTitle(item.title ?? item.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let loaded {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: loaded.originalURL) {
                            Label("Share Original", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task(id: item.asset?.digest) {
            do {
                loaded = try await TrayImageLoader.thumbnail(
                    for: item,
                    tray: tray,
                    maxPixelSize: 2_048
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TrayImageThumbnail: View {
    let item: TrayItem
    let tray: Tray
    let maxPixelSize: Int

    @State private var image: UIImage?
    @State private var isUnavailable = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isUnavailable {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Image unavailable")
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: item.asset?.digest) {
            do {
                image = try await TrayImageLoader.thumbnail(
                    for: item,
                    tray: tray,
                    maxPixelSize: maxPixelSize
                ).image
            } catch {
                isUnavailable = true
            }
        }
    }
}
