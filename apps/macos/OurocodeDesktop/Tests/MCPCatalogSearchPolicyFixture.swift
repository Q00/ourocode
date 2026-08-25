import AppKit
import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum MCPCatalogSearchPolicyFixture {
    static func main() {
        require(
            MCPCatalogSearchPolicy.normalizedQuery("  RÉSUMÉ  ") == "resume",
            "query normalization lost case/diacritic-insensitive matching"
        )
        require(
            MCPCatalogSearchPolicy.normalizedQuery(String(repeating: "x", count: 200)).count
                == MCPCatalogSearchPolicy.maximumQueryCharacters,
            "pasted query escaped its character bound"
        )

        let records = [
            MCPCatalogSearchRecord(id: "source:notes", searchableText: "Local Notes connected"),
            MCPCatalogSearchRecord(
                id: "collection:notes:tools",
                ancestry: ["source:notes"],
                searchableText: "Tools Callable operations"
            ),
            MCPCatalogSearchRecord(
                id: "notes:find_note",
                ancestry: ["source:notes", "collection:notes:tools"],
                searchableText: "find_note Find a note by exact title"
            ),
        ]
        let projection = MCPCatalogSearchPolicy.project(records: records, query: "EXACT TITLE")
        require(projection.visibleIDs.contains("notes:find_note"), "matching item was filtered out")
        require(projection.visibleIDs.contains("source:notes"), "matching item lost its source ancestor")
        require(projection.visibleIDs.contains("collection:notes:tools"), "matching item lost its collection ancestor")
        require(projection.examinedRecordCount == records.count, "small search did not examine a deterministic record count")

        let oversized = (0...MCPCatalogSearchPolicy.maximumRecordsExamined).map {
            MCPCatalogSearchRecord(id: "item:\($0)", searchableText: "needle \($0)")
        }
        let bounded = MCPCatalogSearchPolicy.project(records: oversized, query: "needle")
        require(bounded.reachedWorkLimit, "oversized search did not report its work bound")
        require(
            bounded.examinedRecordCount == MCPCatalogSearchPolicy.maximumRecordsExamined,
            "oversized search examined records beyond its budget"
        )
        require(
            !bounded.visibleIDs.contains("item:\(MCPCatalogSearchPolicy.maximumRecordsExamined)"),
            "record beyond the work budget leaked into results"
        )

        require(
            MCPCatalogSearchPolicy.retainedSelection(
                activeID: nil,
                retainedID: "notes:find_note",
                query: "missing",
                visibleIDs: []
            ) == "notes:find_note",
            "temporarily hidden selection was not retained"
        )
        require(
            MCPCatalogSearchPolicy.retainedSelection(
                activeID: "notes:summarize",
                retainedID: "notes:find_note",
                query: "note",
                visibleIDs: ["notes:summarize"]
            ) == "notes:summarize",
            "new visible selection did not replace the retained identity"
        )

        require(
            MCPCatalogSearchPolicy.shouldClearQuery(from: .mcp, to: .sessions),
            "MCP-scoped query leaked into Sessions mode"
        )
        require(
            !MCPCatalogSearchPolicy.shouldClearQueryOnSourceSelectionChange(),
            "global catalog query was cleared by source selection"
        )

        print("PASS: MCP catalog search is bounded, hierarchy-preserving, and selection-stable")
    }
}
