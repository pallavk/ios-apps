import Foundation

struct TraySearchFilter: Equatable, Sendable {
    static let all = TraySearchFilter()

    let kind: TrayItemKind?
    let collectionID: UUID?

    init(kind: TrayItemKind? = nil, collectionID: UUID? = nil) {
        self.kind = kind
        self.collectionID = collectionID
    }

    func includes(_ item: TrayItem) -> Bool {
        (kind == nil || item.kind == kind)
            && (collectionID == nil || item.collectionID == collectionID)
    }
}

struct TraySnapshot: Equatable, Sendable {
    static let empty = TraySnapshot(recent: [], pinned: [], trash: [], collections: [])

    let recent: [TrayItem]
    let pinned: [TrayItem]
    let trash: [TrayItem]
    let collections: [TrayCollection]

    func search(_ query: String, filter: TraySearchFilter = .all) -> [TrayItem] {
        let normalizedQuery = Self.searchKey(query)
        guard !normalizedQuery.isEmpty else { return recent.filter(filter.includes) }
        let collectionNames = Dictionary(
            uniqueKeysWithValues: collections.map { ($0.id, $0.name) }
        )
        var scored: [(index: Int, item: TrayItem, score: Int)] = []
        for (index, item) in recent.enumerated() where filter.includes(item) {
            guard let score = Self.searchScore(
                item,
                query: normalizedQuery,
                collectionName: item.collectionID.flatMap { collectionNames[$0] }
            ) else { continue }
            scored.append((index, item, score))
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return scored.map(\.item)
    }

    private static func searchScore(
        _ item: TrayItem,
        query: String,
        collectionName: String?
    ) -> Int? {
        let weightedValues: [(String?, Int)] = [
            (item.title, 60),
            (item.note, 40),
            (collectionName, 35),
            (item.text, 25),
            (item.analysis?.searchableText, 15),
        ]
        let extraValues = (item.analysis?.entities.map(\.value) ?? [])
            + (item.analysis?.actions.map(\.value) ?? [])
        var bestScore: Int?
        for (value, weight) in weightedValues where value != nil {
            let key = searchKey(value!)
            guard key.contains(query) else { continue }
            let matchBonus = key == query ? 20 : (key.hasPrefix(query) ? 10 : 0)
            bestScore = max(bestScore ?? 0, weight + matchBonus)
        }
        for value in extraValues where searchKey(value).contains(query) {
            bestScore = max(bestScore ?? 0, 10)
        }
        return bestScore
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
