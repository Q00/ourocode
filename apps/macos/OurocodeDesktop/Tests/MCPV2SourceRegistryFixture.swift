import Foundation

#if MCP_V2_CATALOG_STANDALONE
struct MCPBrowserEntry: Equatable {
    let id: String
    let title: String
    let detail: String
}

struct MCPSourceCatalog: Equatable {
    var protocolVersion = "2025-06-18"
    var serverName = "Ouroboros"
    var serverVersion = "unknown"
    var endpoint = "Local process"
    var capabilities: [String] = []
    var toolsStatus = "Unsupported"
    var resourcesStatus = "Unsupported"
    var promptsStatus = "Unsupported"
    var tools: [MCPBrowserEntry] = []
    var resources: [MCPBrowserEntry] = []
    var prompts: [MCPBrowserEntry] = []
}

enum OuroborosConnectionState: Equatable {
    case starting
    case connected(version: String)
    case offline(reason: String)
}

enum MCPCollectionKind: Hashable { case tools, resources, prompts }

protocol MCPSourceAdapter: AnyObject {
    var onStateChange: ((OuroborosConnectionState) -> Void)? { get set }
    var onCatalogChange: ((MCPSourceCatalog) -> Void)? { get set }
    func start()
    func stop()
    func retry()
    func pauseObservation()
    func resumeObservation()
}

protocol MCPLazyCatalogSourceAdapter: MCPSourceAdapter {
    func requestCollection(_ kind: MCPCollectionKind)
}
#endif

private enum FixtureError: Error { case expectedInitializeFailure }

private final class DeterministicSecondMCPTransport: MCPV2CatalogTransport {
    private let lock = NSLock()
    private(set) var methods: [String] = []
    private(set) var notifications: [String] = []
    private(set) var cancellations = 0
    var failNextInitialize = false

    func request(
        id: Int,
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        lock.lock()
        methods.append(method)
        if method == "initialize", failNextInitialize {
            failNextInitialize = false
            lock.unlock()
            completion(.failure(FixtureError.expectedInitializeFailure))
            return
        }
        lock.unlock()

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "fixture-notes", "version": "2.0.0"],
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false],
                    "prompts": ["listChanged": false]
                ]
            ]
        case "tools/list":
            if params["cursor"] as? String == "tools-2" {
                // A further cursor proves the adapter stops at its configured
                // page bound instead of walking an untrusted stream forever.
                result = [
                    "tools": [["name": "summarize", "description": "Summarize one bounded note"]],
                    "nextCursor": "tools-3"
                ]
            } else {
                result = [
                    "tools": [["name": "find_note", "description": "Find one note"]],
                    "nextCursor": "tools-2"
                ]
            }
        case "resources/list":
            if params["cursor"] as? String == "resources-2" {
                result = ["resources": [["uri": "notes://two", "name": "Second note"]]]
            } else {
                result = [
                    "resources": [["uri": "notes://one", "name": "First note"]],
                    "nextCursor": "resources-2"
                ]
            }
        case "prompts/list":
            if params["cursor"] as? String == "prompts-2" {
                result = ["prompts": [["name": "review_note", "description": "Review a note"]]]
            } else {
                result = [
                    "prompts": [["name": "draft_note", "description": "Draft a note"]],
                    "nextCursor": "prompts-2"
                ]
            }
        default:
            preconditionFailure("unexpected fixture method: \(method)")
        }
        completion(.success(try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result
        ], options: [.sortedKeys])))
    }

    func notify(method: String, params _: [String: Any]) {
        lock.lock(); notifications.append(method); lock.unlock()
    }

    func cancel() {
        lock.lock(); cancellations += 1; lock.unlock()
    }

    func methodCount(_ method: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return methods.filter { $0 == method }.count
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func wait(_ semaphore: DispatchSemaphore, _ message: String) {
    require(semaphore.wait(timeout: .now() + 3) == .success, message)
}

@main
private enum MCPV2SourceRegistryFixture {
    static func main() throws {
        let ouroborosID = MCPSourceID(rawValue: "ouroboros")!
        let notesID = MCPSourceID(rawValue: "fixture-notes")!
        let transport = DeterministicSecondMCPTransport()
        let callbackQueue = DispatchQueue(label: "fixture.callbacks")
        let second = MCPV2CatalogAdapter(
            configuration: MCPV2CatalogConfiguration(
                displayName: "Fixture Notes",
                endpointDescription: "Deterministic local MCP v2 fixture",
                limits: MCPV2CatalogLimits(
                    maximumResponseBytes: 16_384,
                    maximumPagesPerCollection: 2,
                    maximumEntriesPerCollection: 8,
                    maximumTextCharacters: 80
                ),
                callbackQueue: callbackQueue
            ),
            transport: transport
        )
        let inert = InertAdapter()
        let registry = try MCPSourceRegistry([
            MCPSourceRegistration(id: ouroborosID, displayName: "Ouroboros") { inert },
            MCPSourceRegistration(id: notesID, displayName: "Fixture Notes") { second }
        ])
        require(registry.registrations.map(\.id) == [ouroborosID, notesID], "registry lost deterministic order")
        require(registry.makeAdapters().count == 2, "registry retained a one-source assumption")
        require(registry.registration(for: notesID)?.displayName == "Fixture Notes", "typed lookup failed")
        let computerUseDescriptor = LocalMCPSourceDescriptor(
            schemaVersion: 1,
            id: "computer-use",
            displayName: "Computer Use",
            endpointManifestPath: "/fixture/cua-endpoint.json"
        )
        let productionRegistry = DesktopMCPSourceRegistry.make(
            ouroborosAdapter: inert,
            localDescriptors: [computerUseDescriptor],
            includeCatalogDemoFixture: false
        )
        require(
            productionRegistry.registrations.map(\.id) == [
                ouroborosID,
                MCPSourceID(rawValue: "computer-use")!,
            ],
            "production registry did not expose Computer Use after Ouroboros"
        )
        let explicitDemoRegistry = DesktopMCPSourceRegistry.make(
            ouroborosAdapter: inert,
            localDescriptors: [computerUseDescriptor],
            includeCatalogDemoFixture: true
        )
        require(
            explicitDemoRegistry.registrations.map(\.id) == [
                ouroborosID,
                MCPSourceID(rawValue: "computer-use")!,
                MCPV2CatalogDemoFixture.sourceID,
            ],
            "explicit demo registry lost deterministic source ordering"
        )
        require(
            explicitDemoRegistry.makeAdapters()[2].adapter is MCPV2CatalogAdapter,
            "demo source did not use the generic MCP v2 adapter"
        )
        do {
            _ = try MCPSourceRegistry([
                MCPSourceRegistration(id: notesID, displayName: "One") { inert },
                MCPSourceRegistration(id: notesID, displayName: "Two") { inert }
            ])
            require(false, "duplicate source id did not fail closed")
        } catch MCPSourceRegistryError.duplicateID(let id) {
            require(id == notesID, "duplicate failure reported the wrong id")
        }

        let connected = DispatchSemaphore(value: 0)
        let loaded = DispatchSemaphore(value: 0)
        let offline = DispatchSemaphore(value: 0)
        let reconnected = DispatchSemaphore(value: 0)
        var connectedCount = 0
        var latestCatalog: MCPSourceCatalog?
        second.onStateChange = { state in
            switch state {
            case .connected:
                connectedCount += 1
                (connectedCount == 1 ? connected : reconnected).signal()
            case .offline:
                offline.signal()
            case .starting:
                break
            }
        }
        second.onCatalogChange = { catalog in
            latestCatalog = catalog
            if catalog.tools.count == 2, catalog.resources.count == 2, catalog.prompts.count == 2 {
                loaded.signal()
            }
        }

        // Lazy requests may precede connection; initialization gates and then
        // drains them only after capabilities are negotiated.
        second.requestCollection(.tools)
        second.requestCollection(.resources)
        second.requestCollection(.prompts)
        second.start()
        wait(connected, "second MCP v2 source did not initialize")
        wait(loaded, "bounded paginated collections did not load")
        callbackQueue.sync {}

        require(latestCatalog?.serverName == "fixture-notes", "initialize server info was not projected")
        require(latestCatalog?.capabilities == ["prompts", "resources", "tools"], "capabilities were not negotiated")
        require(latestCatalog?.toolsStatus == "2 shown · page limit reached", "tool pagination was not bounded")
        require(transport.methodCount("tools/list") == 2, "tool paginator exceeded its page limit")
        require(transport.methodCount("resources/list") == 2, "resource pagination did not follow its cursor")
        require(transport.methodCount("prompts/list") == 2, "prompt pagination did not follow its cursor")
        require(transport.notifications == ["notifications/initialized"], "initialized notification mismatch")

        transport.failNextInitialize = true
        second.retry()
        wait(offline, "failed reconnect did not expose an offline state")
        second.retry()
        wait(reconnected, "manual reconnect did not renegotiate the source")
        callbackQueue.sync {}
        require(transport.notifications.count == 2, "reconnect skipped initialized notification")
        require(transport.cancellations >= 2, "reconnect did not invalidate prior transport work")

        second.stop()
        print("PASS: production-one/demo-two registry, MCP v2 negotiation, bounded paginated catalogs, and reconnect state")
    }
}

private final class InertAdapter: MCPSourceAdapter {
    var onStateChange: ((OuroborosConnectionState) -> Void)?
    var onCatalogChange: ((MCPSourceCatalog) -> Void)?
    func start() {}
    func stop() {}
    func retry() {}
    func pauseObservation() {}
    func resumeObservation() {}
}
