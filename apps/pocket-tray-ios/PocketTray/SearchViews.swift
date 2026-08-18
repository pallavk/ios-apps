import SwiftUI

enum LocalSearchHistory {
    static func entries(from storage: String) -> [String] {
        storage.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func adding(_ rawQuery: String, to entries: [String], snapshot: TraySnapshot) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        guard DeterministicSensitiveContentClassifier().reasons(in: query).isEmpty else {
            return entries
        }
        guard !snapshot.search(query).contains(where: \.protectsSensitivePreview) else {
            return entries
        }
        var updated = entries.filter {
            $0.localizedCaseInsensitiveCompare(query) != .orderedSame
        }
        updated.insert(query, at: 0)
        return Array(updated.prefix(6))
    }

    static func removing(_ query: String, from entries: [String]) -> [String] {
        entries.filter { $0 != query }
    }

    static func sanitized(_ entries: [String], for snapshot: TraySnapshot) -> [String] {
        entries.filter { query in
            DeterministicSensitiveContentClassifier().reasons(in: query).isEmpty
                && !snapshot.search(query).contains(where: \.protectsSensitivePreview)
        }
    }
}

enum SearchKindFilter: String, CaseIterable, Hashable {
    case all, text, links, images, pdfs

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .text: String(localized: "Text")
        case .links: String(localized: "Links")
        case .images: String(localized: "Images")
        case .pdfs: String(localized: "PDFs")
        }
    }

    var itemKind: TrayItemKind? {
        switch self {
        case .all: nil
        case .text: .text
        case .links: .url
        case .images: .image
        case .pdfs: .pdf
        }
    }
}

private extension TrayItemKind {
    var accessibilityName: String {
        switch self {
        case .image: String(localized: "Image")
        case .pdf: String(localized: "PDF")
        case .text: String(localized: "Text")
        case .url: String(localized: "Link")
        }
    }
}

struct SearchFilterBar: View {
    let collections: [TrayCollection]
    @Binding var kind: SearchKindFilter
    @Binding var collectionID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Object Type", selection: $kind) {
                        ForEach(SearchKindFilter.allCases, id: \.self) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    filterLabel(kind.title, systemImage: "line.3.horizontal.decrease.circle")
                }
                Menu {
                    Button("Any Collection") { collectionID = nil }
                    ForEach(collections) { collection in
                        Button(collection.name) { collectionID = collection.id }
                    }
                } label: {
                    filterLabel(collectionName, systemImage: "folder")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search filters")
    }

    private var collectionName: String {
        guard let collectionID else { return String(localized: "Any Collection") }
        return collections.first { $0.id == collectionID }?.name
            ?? String(localized: "Any Collection")
    }

    private func filterLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
    }
}

struct SearchDiscoveryView: View {
    let recentItems: [TrayItem]
    let collections: [TrayCollection]
    let recentSearches: [String]
    let selectQuery: (String) -> Void
    let selectCollection: (UUID) -> Void
    let removeSearch: (String) -> Void
    let openItem: (TrayItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !recentSearches.isEmpty {
                    sectionTitle(String(localized: "Recent Searches"))
                    ForEach(recentSearches, id: \.self) { query in
                        HStack {
                            Button { selectQuery(query) } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button { removeSearch(query) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Remove search \(query)")
                        }
                    }
                }
                if !collections.isEmpty {
                    sectionTitle(String(localized: "Collections"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(collections) { collection in
                                Button { selectCollection(collection.id) } label: {
                                    Label(collection.name, systemImage: "folder")
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !recentItems.isEmpty {
                    sectionTitle(String(localized: "Recently Saved"))
                    ForEach(recentItems.prefix(5)) { item in
                        Button { openItem(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.kind.systemImage)
                                    .frame(width: 24)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title ?? item.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(item.kind.accessibilityName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if recentItems.isEmpty && collections.isEmpty && recentSearches.isEmpty {
                    ContentUnavailableView(
                        "Nothing to search yet",
                        systemImage: "magnifyingglass",
                        description: Text("Saved objects and collections will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }
}
