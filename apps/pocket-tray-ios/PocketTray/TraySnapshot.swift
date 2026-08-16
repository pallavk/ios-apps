import Foundation

struct TraySnapshot: Equatable, Sendable {
    static let empty = TraySnapshot(recent: [], pinned: [], trash: [], collections: [])

    let recent: [TrayItem]
    let pinned: [TrayItem]
    let trash: [TrayItem]
    let collections: [TrayCollection]

    func search(_ query: String) -> [TrayItem] {
        let normalizedQuery = Self.searchKey(query)
        guard !normalizedQuery.isEmpty else { return recent }
        let collectionNames = Dictionary(
            uniqueKeysWithValues: collections.map { ($0.id, $0.name) }
        )
        return recent.filter { item in
            let values = [
                item.text,
                item.title,
                item.note,
                item.collectionID.flatMap { collectionNames[$0] },
                item.analysis?.searchableText
            ].compactMap { $0 }
                + (item.analysis?.entities.map(\.value) ?? [])
                + (item.analysis?.actions.map(\.value) ?? [])
            return values.contains { value in
                Self.searchKey(value).contains(normalizedQuery)
            }
        }
    }

    private static func searchKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
