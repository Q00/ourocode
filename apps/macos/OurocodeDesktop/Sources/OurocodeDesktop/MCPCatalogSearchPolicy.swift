import Foundation

/// The MCP catalog is user-facing navigation, so search must stay cheap and
/// deterministic even when a server advertises a very large registry. The
/// controller supplies one record per visible node; this policy only decides
/// which stable IDs survive the filter.
struct MCPCatalogSearchRecord: Equatable {
    let id: String
    let ancestry: [String]
    let searchableText: String

    init(id: String, ancestry: [String] = [], searchableText: String) {
        self.id = id
        self.ancestry = ancestry
        self.searchableText = searchableText
    }
}

struct MCPCatalogSearchProjection: Equatable {
    let normalizedQuery: String
    let visibleIDs: Set<String>
    let examinedRecordCount: Int
    let reachedWorkLimit: Bool

    var hasMatches: Bool { !visibleIDs.isEmpty }
}

enum MCPCatalogSearchPolicy {
    /// A long paste should never turn every keystroke into unbounded work.
    static let maximumQueryCharacters = 128
    /// This bounds the main-thread projection while still covering the normal
    /// MCP desktop budget (16 sources × 512 entries per collection).
    static let maximumRecordsExamined = 8_192
    static let debounceMilliseconds = 120

    static func normalizedQuery(_ raw: String) -> String {
        let bounded = String(raw.prefix(maximumQueryCharacters))
        return bounded
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    static func shouldClearQuery(from oldMode: SessionRailMode, to newMode: SessionRailMode) -> Bool {
        oldMode == .mcp && newMode == .sessions
    }

    /// Source selection does not clear the query: the catalog is intentionally
    /// global, and moving between providers should not make the user's search
    /// disappear. Mode transitions are handled by `shouldClearQuery` above.
    static func shouldClearQueryOnSourceSelectionChange() -> Bool { false }

    static func project(
        records: [MCPCatalogSearchRecord],
        query rawQuery: String
    ) -> MCPCatalogSearchProjection {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else {
            return MCPCatalogSearchProjection(
                normalizedQuery: query,
                visibleIDs: Set(records.map(\.id)),
                examinedRecordCount: 0,
                reachedWorkLimit: false
            )
        }

        let boundedRecords = records.prefix(maximumRecordsExamined)
        var visibleIDs = Set<String>()
        var examined = 0
        for record in boundedRecords {
            examined += 1
            let text = record.searchableText
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .lowercased()
            guard text.localizedStandardRange(of: query) != nil else { continue }
            visibleIDs.insert(record.id)
            visibleIDs.formUnion(record.ancestry)
        }
        return MCPCatalogSearchProjection(
            normalizedQuery: query,
            visibleIDs: visibleIDs,
            examinedRecordCount: examined,
            reachedWorkLimit: records.count > maximumRecordsExamined
        )
    }

    /// Keep logical selection separate from the filtered outline. This lets a
    /// result that temporarily disappears return when the query is cleared.
    static func retainedSelection(
        activeID: String?,
        retainedID: String?,
        query rawQuery: String,
        visibleIDs: Set<String>
    ) -> String? {
        let query = normalizedQuery(rawQuery)
        if query.isEmpty { return retainedID ?? activeID }
        if let activeID, visibleIDs.contains(activeID) { return activeID }
        return retainedID
    }
}
