import Foundation

/// Request/response boundary for a generic MCP v2 catalog source. Concrete
/// transports must establish their own local or mutually authenticated trust;
/// this layer intentionally has no bearer-token or plain remote HTTP path.
protocol MCPV2CatalogTransport: AnyObject {
    func request(
        id: Int,
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    )
    func notify(method: String, params: [String: Any])
    func cancel()
}

struct MCPV2CatalogLimits: Equatable {
    let maximumResponseBytes: Int
    let maximumPagesPerCollection: Int
    let maximumEntriesPerCollection: Int
    let maximumTextCharacters: Int

    static let desktop = MCPV2CatalogLimits(
        maximumResponseBytes: 1_048_576,
        maximumPagesPerCollection: 8,
        maximumEntriesPerCollection: 512,
        maximumTextCharacters: 240
    )
}

struct MCPV2CatalogConfiguration {
    let displayName: String
    let endpointDescription: String
    let protocolVersion: String
    let limits: MCPV2CatalogLimits
    let callbackQueue: DispatchQueue

    init(
        displayName: String,
        endpointDescription: String,
        protocolVersion: String = "2025-06-18",
        limits: MCPV2CatalogLimits = .desktop,
        callbackQueue: DispatchQueue = .main
    ) {
        self.displayName = displayName
        self.endpointDescription = endpointDescription
        self.protocolVersion = protocolVersion
        self.limits = limits
        self.callbackQueue = callbackQueue
    }
}

/// Provider-neutral MCP v2 catalog adapter. It negotiates the protocol before
/// exposing capabilities, loads collections lazily, follows only bounded and
/// non-repeating cursors, and invalidates late replies on stop/reconnect.
final class MCPV2CatalogAdapter: MCPLazyCatalogSourceAdapter {
    private enum RequestFailure: Error {
        case rejected(String)

        var message: String {
            switch self { case .rejected(let message): message }
        }
    }

    var onStateChange: ((OuroborosConnectionState) -> Void)?
    var onCatalogChange: ((MCPSourceCatalog) -> Void)?

    private let configuration: MCPV2CatalogConfiguration
    private let transport: MCPV2CatalogTransport
    private let queue: DispatchQueue
    private var catalog: MCPSourceCatalog
    private var generation: UInt64 = 0
    private var requestID = 0
    private var started = false
    private var observationActive = false
    private var connected = false
    private var supportedCollections = Set<MCPCollectionKind>()
    private var requestedCollections = Set<MCPCollectionKind>()
    private var loadingCollections = Set<MCPCollectionKind>()

    init(configuration: MCPV2CatalogConfiguration, transport: MCPV2CatalogTransport) {
        self.configuration = configuration
        self.transport = transport
        self.queue = DispatchQueue(label: "com.ourolabs.ourocode.mcp-v2.catalog.\(UUID().uuidString)")
        self.catalog = MCPSourceCatalog(
            serverName: configuration.displayName,
            endpoint: configuration.endpointDescription
        )
    }

    deinit { transport.cancel() }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.observationActive = true
            guard !self.started else { return }
            self.started = true
            self.beginInitialization()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.started = false
            self.observationActive = false
            self.connected = false
            self.loadingCollections.removeAll(keepingCapacity: true)
            self.transport.cancel()
        }
    }

    func retry() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.transport.cancel()
            self.started = true
            self.observationActive = true
            self.connected = false
            self.loadingCollections.removeAll(keepingCapacity: true)
            self.beginInitialization()
        }
    }

    func pauseObservation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.observationActive = false
            self.generation &+= 1
            self.loadingCollections.removeAll(keepingCapacity: true)
            self.transport.cancel()
        }
    }

    func resumeObservation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.observationActive = true
            if self.connected {
                for kind in self.requestedCollections { self.load(kind) }
            } else if self.started {
                self.beginInitialization()
            } else {
                self.started = true
                self.beginInitialization()
            }
        }
    }

    func requestCollection(_ kind: MCPCollectionKind) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedCollections.insert(kind)
            self.load(kind)
        }
    }

    private func beginInitialization() {
        generation &+= 1
        let activeGeneration = generation
        connected = false
        supportedCollections.removeAll(keepingCapacity: true)
        publishState(.starting)
        send(
            method: "initialize",
            params: [
                "protocolVersion": configuration.protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "ourocode-desktop", "version": "0.1.0"]
            ],
            generation: activeGeneration
        ) { [weak self] result in
            guard let self, self.generation == activeGeneration else { return }
            switch result {
            case .failure(let failure):
                self.failConnection(failure.message)
            case .success(let response):
                self.finishInitialization(response, generation: activeGeneration)
            }
        }
    }

    private func finishInitialization(_ response: [String: Any], generation: UInt64) {
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              let protocolVersion = result["protocolVersion"] as? String,
              protocolVersion == configuration.protocolVersion,
              let serverInfo = result["serverInfo"] as? [String: Any],
              let serverName = nonempty(serverInfo["name"] as? String),
              let serverVersion = nonempty(serverInfo["version"] as? String),
              let capabilities = result["capabilities"] as? [String: Any] else {
            failConnection("MCP initialization contract was rejected")
            return
        }

        supportedCollections = Set(MCPCollectionKind.allCases.filter { capabilities[$0.capabilityKey] != nil })
        catalog = MCPSourceCatalog(
            protocolVersion: protocolVersion,
            serverName: bounded(serverName),
            serverVersion: bounded(serverVersion),
            endpoint: configuration.endpointDescription,
            capabilities: capabilities.keys.sorted(),
            toolsStatus: initialStatus(for: .tools),
            resourcesStatus: initialStatus(for: .resources),
            promptsStatus: initialStatus(for: .prompts)
        )
        connected = true
        transport.notify(method: "notifications/initialized", params: [:])
        publishCatalog()
        publishState(.connected(version: catalog.serverVersion))
        guard observationActive, self.generation == generation else { return }
        for kind in requestedCollections { load(kind) }
    }

    private func load(_ kind: MCPCollectionKind) {
        guard observationActive, connected, supportedCollections.contains(kind),
              !loadingCollections.contains(kind) else { return }
        loadingCollections.insert(kind)
        set(kind, entries: entries(for: kind), status: "Loading…")
        loadPage(kind, cursor: nil, seenCursors: [], pages: 0, accumulated: [], generation: generation)
    }

    private func loadPage(
        _ kind: MCPCollectionKind,
        cursor: String?,
        seenCursors: Set<String>,
        pages: Int,
        accumulated: [MCPBrowserEntry],
        generation: UInt64
    ) {
        guard pages < configuration.limits.maximumPagesPerCollection else {
            finishBounded(kind, entries: accumulated, suffix: "page limit reached")
            return
        }
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        send(method: kind.listMethod, params: params, generation: generation) { [weak self] result in
            guard let self, self.generation == generation, self.observationActive else { return }
            switch result {
            case .failure(let failure):
                self.loadingCollections.remove(kind)
                self.set(kind, entries: accumulated, status: "Unavailable · \(failure.message)")
            case .success(let response):
                guard response["error"] == nil,
                      let payload = response["result"] as? [String: Any],
                      let rawEntries = payload[kind.resultKey] as? [[String: Any]] else {
                    self.loadingCollections.remove(kind)
                    self.set(kind, entries: accumulated, status: "Unavailable · invalid response")
                    return
                }
                let remaining = max(0, self.configuration.limits.maximumEntriesPerCollection - accumulated.count)
                let parsed = rawEntries.prefix(remaining).compactMap { self.parse($0, kind: kind) }
                let combined = accumulated + parsed
                let next = self.nonempty(payload["nextCursor"] as? String)
                guard combined.count < self.configuration.limits.maximumEntriesPerCollection,
                      rawEntries.count <= remaining,
                      let next else {
                    let truncated = rawEntries.count > remaining || next != nil
                    self.finishBounded(kind, entries: combined, suffix: truncated ? "entry limit reached" : nil)
                    return
                }
                guard !seenCursors.contains(next) else {
                    self.loadingCollections.remove(kind)
                    self.set(kind, entries: combined, status: "Unavailable · repeated cursor")
                    return
                }
                var nextSeen = seenCursors
                nextSeen.insert(next)
                self.loadPage(
                    kind,
                    cursor: next,
                    seenCursors: nextSeen,
                    pages: pages + 1,
                    accumulated: combined,
                    generation: generation
                )
            }
        }
    }

    private func finishBounded(_ kind: MCPCollectionKind, entries: [MCPBrowserEntry], suffix: String?) {
        loadingCollections.remove(kind)
        let status = suffix.map { "\(entries.count) shown · \($0)" }
            ?? (entries.isEmpty ? "Empty" : "\(entries.count)")
        set(kind, entries: entries, status: status)
    }

    private func send(
        method: String,
        params: [String: Any],
        generation: UInt64,
        completion: @escaping (Result<[String: Any], RequestFailure>) -> Void
    ) {
        requestID += 1
        let id = requestID
        transport.request(id: id, method: method, params: params) { [weak self] result in
            self?.queue.async {
                guard let self, self.generation == generation else { return }
                switch result {
                case .failure(let error): completion(.failure(.rejected(self.bounded(error.localizedDescription))))
                case .success(let data):
                    guard data.count <= self.configuration.limits.maximumResponseBytes else {
                        completion(.failure(.rejected("response exceeded safety bound")))
                        return
                    }
                    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          response["jsonrpc"] as? String == "2.0",
                          response["id"] as? Int == id else {
                        completion(.failure(.rejected("invalid JSON-RPC response")))
                        return
                    }
                    completion(.success(response))
                }
            }
        }
    }

    private func parse(_ value: [String: Any], kind: MCPCollectionKind) -> MCPBrowserEntry? {
        switch kind {
        case .tools, .prompts:
            guard let name = nonempty(value["name"] as? String) else { return nil }
            return MCPBrowserEntry(
                id: "\(kind.idPrefix):\(bounded(name))",
                title: bounded(name),
                detail: bounded(value["description"] as? String ?? kind.fallbackDetail)
            )
        case .resources:
            guard let uri = nonempty(value["uri"] as? String) else { return nil }
            return MCPBrowserEntry(
                id: "resource:\(bounded(uri))",
                title: bounded(value["name"] as? String ?? uri),
                detail: bounded(value["description"] as? String ?? uri)
            )
        }
    }

    private func initialStatus(for kind: MCPCollectionKind) -> String {
        supportedCollections.contains(kind) ? "Available · expand to load" : "Unsupported"
    }

    private func entries(for kind: MCPCollectionKind) -> [MCPBrowserEntry] {
        switch kind {
        case .tools: catalog.tools
        case .resources: catalog.resources
        case .prompts: catalog.prompts
        }
    }

    private func set(_ kind: MCPCollectionKind, entries: [MCPBrowserEntry], status: String) {
        switch kind {
        case .tools: catalog.tools = entries; catalog.toolsStatus = status
        case .resources: catalog.resources = entries; catalog.resourcesStatus = status
        case .prompts: catalog.prompts = entries; catalog.promptsStatus = status
        }
        publishCatalog()
    }

    private func failConnection(_ reason: String) {
        connected = false
        loadingCollections.removeAll(keepingCapacity: true)
        publishState(.offline(reason: bounded(reason)))
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func bounded(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(2, configuration.limits.maximumTextCharacters)
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit - 1)) + "…"
    }

    private func publishState(_ state: OuroborosConnectionState) {
        configuration.callbackQueue.async { [weak self] in self?.onStateChange?(state) }
    }

    private func publishCatalog() {
        let snapshot = catalog
        configuration.callbackQueue.async { [weak self] in self?.onCatalogChange?(snapshot) }
    }
}

private extension MCPCollectionKind {
    static var allCases: [MCPCollectionKind] { [.tools, .resources, .prompts] }

    var capabilityKey: String {
        switch self { case .tools: "tools"; case .resources: "resources"; case .prompts: "prompts" }
    }

    var listMethod: String {
        switch self { case .tools: "tools/list"; case .resources: "resources/list"; case .prompts: "prompts/list" }
    }

    var resultKey: String {
        switch self { case .tools: "tools"; case .resources: "resources"; case .prompts: "prompts" }
    }

    var idPrefix: String {
        switch self { case .tools: "tool"; case .resources: "resource"; case .prompts: "prompt" }
    }

    var fallbackDetail: String {
        switch self { case .tools: "MCP tool"; case .resources: "MCP resource"; case .prompts: "MCP prompt" }
    }
}
