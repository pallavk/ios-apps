import PDFKit
import SwiftUI

struct LoadedTrayPDF: @unchecked Sendable {
    let document: PDFDocument
    let exportURL: URL
}

struct LoadedTrayPDFThumbnail: @unchecked Sendable {
    let image: UIImage
    let pageCount: Int
}

private actor TrayPDFLoadGate {
    private var availablePermits = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

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
        } else {
            await withCheckedContinuation { waiters.append($0) }
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

enum TrayPDFLoader {
    private static let gate = TrayPDFLoadGate()

    static func load(for item: TrayItem, tray: Tray) async throws -> LoadedTrayPDF {
        try await gate.withPermit {
            try await loadWithoutPermit(for: item, tray: tray)
        }
    }

    static func thumbnail(
        for item: TrayItem,
        tray: Tray,
        size: CGSize
    ) async throws -> LoadedTrayPDFThumbnail {
        try await gate.withPermit {
            let loaded = try await loadWithoutPermit(for: item, tray: tray)
            guard let page = loaded.document.page(at: 0) else {
                throw TrayAssetError.corrupt
            }
            try Task.checkCancellation()
            return LoadedTrayPDFThumbnail(
                image: page.thumbnail(of: size, for: .cropBox),
                pageCount: loaded.document.pageCount
            )
        }
    }

    private static func loadWithoutPermit(
        for item: TrayItem,
        tray: Tray
    ) async throws -> LoadedTrayPDF {
        let resource = try await tray.assetResource(for: item)
        try Task.checkCancellation()
        guard
            let document = PDFDocument(data: resource.data),
            !document.isLocked,
            document.pageCount > 0
        else {
            throw TrayAssetError.corrupt
        }
        return LoadedTrayPDF(document: document, exportURL: resource.exportURL)
    }
}

struct TrayPDFRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: TrayItem
    let collectionName: String?
    let tray: Tray

    @State private var thumbnail: UIImage?
    @State private var pageCount: Int?
    @State private var isUnavailable = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else if isUnavailable {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("PDF unavailable")
                } else {
                    ProgressView()
                }
                Text("PDF")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            .frame(width: 68, height: 88)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.text)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if item.title != nil {
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                if let note = item.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                if let pageCount {
                    Text("\(pageCount) \(pageCount == 1 ? "page" : "pages")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let collectionName {
                    Label(collectionName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TraySensitivityMetadata(item: item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isUnavailable {
                    Label("Original unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                lifecycleLabel.font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .task(id: item.asset?.digest) {
            do {
                let loadedThumbnail = try await TrayPDFLoader.thumbnail(
                    for: item,
                    tray: tray,
                    size: CGSize(width: 160, height: 200)
                )
                thumbnail = loadedThumbnail.image
                pageCount = loadedThumbnail.pageCount
            } catch {
                isUnavailable = true
            }
        }
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

    private var accessibilitySummary: String {
        var parts = ["PDF", item.title ?? item.text]
        if let pageCount { parts.append("\(pageCount) \(pageCount == 1 ? "page" : "pages")") }
        if let collectionName { parts.append("Collection \(collectionName)") }
        if item.protectsSensitivePreview { parts.append("Sensitive") }
        if isUnavailable { parts.append("Original unavailable") }
        parts.append(lifecycleAccessibilityDescription)
        return parts.joined(separator: ". ")
    }

    private var lifecycleAccessibilityDescription: String {
        if let trashedAt = item.trashedAt {
            return "Deleted \(trashedAt.formatted(.relative(presentation: .named)))"
        }
        if item.isPinned { return "Pinned, does not expire" }
        if let expiresAt = item.expiresAt {
            return "Expires \(expiresAt.formatted(.relative(presentation: .named)))"
        }
        return "Saved \(item.capturedAt.formatted(.relative(presentation: .named)))"
    }
}

struct TrayPDFDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: TrayItem
    var collectionName: String? = nil
    let tray: Tray
    var manageCollection: (() -> Void)? = nil

    @State private var loaded: LoadedTrayPDF?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    VStack(alignment: .leading, spacing: 0) {
                        PDFDocumentView(document: loaded.document)
                        Divider()
                        ScrollView {
                            TrayDetailMetadata(
                                item: item,
                                collectionName: collectionName,
                                manageCollection: manageCollection
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .frame(maxHeight: 180)
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "PDF unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Loading PDF…")
                }
            }
            .navigationTitle(item.title ?? item.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let loaded {
                    ShareLink(item: loaded.exportURL) {
                        Label("Share Original", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("detail-primary-action")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        .task(id: item.asset?.digest) {
            do {
                loaded = try await TrayPDFLoader.load(for: item, tray: tray)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
