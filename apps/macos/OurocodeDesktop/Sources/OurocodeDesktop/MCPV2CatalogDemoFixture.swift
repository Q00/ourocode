import Foundation

/// A deterministic second MCP v2 source for screenshots and contract QA.
/// The UI registers it only for `--demo mcp-v2-catalog`; production startup
/// never constructs this transport.
enum MCPV2CatalogDemoFixture {
    static let sourceID = MCPSourceID(rawValue: "fixture-notes")!

    static func registration() -> MCPSourceRegistration {
        MCPSourceRegistration(id: sourceID, displayName: "Local Notes") {
            MCPV2CatalogAdapter(
                configuration: MCPV2CatalogConfiguration(
                    displayName: "Local Notes",
                    endpointDescription: "Deterministic local MCP v2 fixture"
                ),
                transport: Transport()
            )
        }
    }

    private final class Transport: MCPV2CatalogTransport {
        func request(
            id: Int,
            method: String,
            params: [String: Any],
            completion: @escaping (Result<Data, Error>) -> Void
        ) {
            let result: [String: Any]
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": "2025-06-18",
                    "serverInfo": ["name": "local-notes", "version": "2.0.0-fixture"],
                    "capabilities": [
                        "tools": ["listChanged": false],
                        "resources": ["subscribe": false, "listChanged": false],
                        "prompts": ["listChanged": false]
                    ]
                ]
            case "tools/list":
                result = page(
                    cursor: params["cursor"] as? String,
                    secondCursor: "tools-2",
                    first: ["tools": [[
                        "name": "find_note",
                        "description": "Find a note by its exact local title"
                    ]]],
                    second: ["tools": [[
                        "name": "summarize_note",
                        "description": "Summarize one bounded local note"
                    ]]]
                )
            case "resources/list":
                result = page(
                    cursor: params["cursor"] as? String,
                    secondCursor: "resources-2",
                    first: ["resources": [[
                        "uri": "notes://welcome",
                        "name": "Welcome",
                        "description": "A local fixture resource"
                    ]]],
                    second: ["resources": [[
                        "uri": "notes://routing",
                        "name": "Routing notes",
                        "description": "A second local fixture resource"
                    ]]]
                )
            case "prompts/list":
                result = page(
                    cursor: params["cursor"] as? String,
                    secondCursor: "prompts-2",
                    first: ["prompts": [[
                        "name": "draft_note",
                        "description": "Draft a concise local note"
                    ]]],
                    second: ["prompts": [[
                        "name": "review_note",
                        "description": "Review a note for clarity"
                    ]]]
                )
            default:
                result = [:]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": result
            ], options: [.sortedKeys]) else {
                completion(.failure(FixtureError.encodingFailed))
                return
            }
            completion(.success(data))
        }

        func notify(method _: String, params _: [String: Any]) {}
        func cancel() {}

        private func page(
            cursor: String?,
            secondCursor: String,
            first: [String: Any],
            second: [String: Any]
        ) -> [String: Any] {
            if cursor == secondCursor { return second }
            var result = first
            result["nextCursor"] = secondCursor
            return result
        }
    }

    private enum FixtureError: Error {
        case encodingFailed
    }
}
