import Foundation

private final class OuroborosHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

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

struct OuroborosSignalTarget: Equatable {
    let executionID: String
    let scopeID: String
    let attemptID: String
    let contractVersion: Int?
    let acID: String?
    let nodeID: String?
    let label: String
    let content: String
    let displayPath: String?
    let depth: Int
    let modes: Set<String>
    let sessionIdentity: OuroborosSessionAttemptIdentityV1?
    let surface: OuroborosSessionSurfaceResolutionV1

    init(
        executionID: String,
        scopeID: String,
        attemptID: String,
        contractVersion: Int?,
        acID: String?,
        nodeID: String?,
        label: String,
        content: String,
        displayPath: String?,
        depth: Int,
        modes: Set<String>,
        sessionIdentity: OuroborosSessionAttemptIdentityV1? = nil,
        surface: OuroborosSessionSurfaceResolutionV1 = .unbound(.notAdvertised)
    ) {
        self.executionID = executionID
        self.scopeID = scopeID
        self.attemptID = attemptID
        self.contractVersion = contractVersion
        self.acID = acID
        self.nodeID = nodeID
        self.label = label
        self.content = content
        self.displayPath = displayPath
        self.depth = depth
        self.modes = modes
        self.sessionIdentity = sessionIdentity
        self.surface = surface
    }
}

struct OuroborosSessionTab: Equatable {
    let id: String
    let label: String
    let detail: String
    var status: String
    let depth: Int
    var target: OuroborosSignalTarget?
    var sessionIdentity: OuroborosSessionAttemptIdentityV1? = nil
    var surface: OuroborosSessionSurfaceResolutionV1 = .unbound(.notAdvertised)

    init(
        id: String,
        label: String,
        detail: String,
        status: String,
        depth: Int,
        target: OuroborosSignalTarget?,
        sessionIdentity: OuroborosSessionAttemptIdentityV1? = nil,
        surface: OuroborosSessionSurfaceResolutionV1 = .unbound(.notAdvertised)
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.status = status
        self.depth = depth
        self.target = target
        self.sessionIdentity = sessionIdentity
        self.surface = surface
    }
}

struct OuroborosSessionGroup: Equatable {
    let sessionID: String
    let executionID: String
    let title: String
    var status: String
    let activity: String
    let suggestedTier: String?
    var tabs: [OuroborosSessionTab]
}

enum MCPSessionDetailState: Equatable {
    case idle
    case loading(MCPSessionActivation)
    case ready(MCPSessionActivation, OuroborosSessionDetailProjectionV0511.Snapshot)
    case unavailable(MCPSessionActivation, String)

    var activation: MCPSessionActivation? {
        switch self {
        case .idle: nil
        case .loading(let activation), .ready(let activation, _),
             .unavailable(let activation, _): activation
        }
    }
}

enum OuroborosConnectionState: Equatable {
    case starting
    case connected(version: String)
    case offline(reason: String)
}

enum MCPCollectionKind: Hashable {
    case tools
    case resources
    case prompts
}

enum MCPAuthenticatedSteeringState: Equatable {
    case unavailable(reason: String)
    case ready

    var isReady: Bool { self == .ready }

    var composerExplanation: String {
        switch self {
        case .ready: return "Ready for authenticated next-turn delivery"
        case .unavailable(let reason): return "Read-only · \(reason)"
        }
    }
}

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

protocol MCPSessionSourceAdapter: MCPSourceAdapter {
    var onSessionsChange: (([OuroborosSessionGroup]) -> Void)? { get set }
    var onProjectionIssue: ((String?) -> Void)? { get set }
    var onTargetDiscovery: ((MCPSessionTargetDiscoveryResult) -> Void)? { get set }
    var onAuthenticatedSteeringChange: ((MCPAuthenticatedSteeringState) -> Void)? { get set }
    func requestTargets(executionID: String, intentGeneration: UInt64?)
    func steer(target: OuroborosSignalTarget, message: String, completion: @escaping (Result<OuroborosSteeringReceipt, Error>) -> Void)
    /// Refreshes one already-admitted immutable request. This deliberately
    /// bypasses current-target discovery because an attempt may disappear
    /// after accepting a message while its durable receipt keeps advancing.
    func refreshSteering(receipt: OuroborosSteeringReceipt, completion: @escaping (Result<OuroborosSteeringReceipt, Error>) -> Void)
}

extension MCPSessionSourceAdapter {
    func requestTargets(executionID: String) {
        requestTargets(executionID: executionID, intentGeneration: nil)
    }
}

/// Optional selected-session detail extension. Keeping activation separate
/// from the session index lets a future Rust broker adapter replace the exact
/// Ouroboros 0.51.6 text parser without changing the Sources rail.
protocol MCPSessionDetailSourceAdapter: MCPSourceAdapter {
    var onSessionDetailChange: ((MCPSessionDetailState) -> Void)? { get set }
    func activateSession(_ activation: MCPSessionActivation)
    func deactivateSession(_ activation: MCPSessionActivation)
    func refreshSession(_ activation: MCPSessionActivation)
}

extension MCPSessionDetailSourceAdapter {
    func refreshSession(_ activation: MCPSessionActivation) {
        activateSession(activation)
    }
}

protocol MCPRoutingSourceAdapter: MCPSourceAdapter {
    var onRoutingContractChange: ((OuroborosRoutingContractState) -> Void)? { get set }
}

final class OuroborosMCPClient: MCPSessionSourceAdapter, MCPSessionDetailSourceAdapter,
    MCPRoutingSourceAdapter, MCPLazyCatalogSourceAdapter {
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let snapshotRefreshSeconds: TimeInterval = 15
    private static let sessionDetailRefreshSeconds = SessionStreamRefreshPolicy.interval
    private static let maximumConcurrentTargetRefreshes = 2
    private static let maximumConcurrentStatusRefreshes = 2
    private static let maximumStatusCandidates = 12
    private static let maximumStatusResponseTextBytes = 64 * 1_024
    private static let expectedServerName = "ouroboros-mcp"
    private static let expectedServerVersion = "0.51.6"

    var onStateChange: ((OuroborosConnectionState) -> Void)?
    var onSessionsChange: (([OuroborosSessionGroup]) -> Void)?
    var onProjectionIssue: ((String?) -> Void)?
    var onTargetDiscovery: ((MCPSessionTargetDiscoveryResult) -> Void)?
    var onAuthenticatedSteeringChange: ((MCPAuthenticatedSteeringState) -> Void)?
    var onSessionDetailChange: ((MCPSessionDetailState) -> Void)?
    var onCatalogChange: ((MCPSourceCatalog) -> Void)?
    var onRoutingContractChange: ((OuroborosRoutingContractState) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.ourolabs.ourocode.mcp-v2")
    private var requestID = 0
    private var pending: [Int: PendingRequest] = [:]
    private var groups: [OuroborosSessionGroup] = []
    private var refreshInFlight = false
    private var refreshTimer: DispatchSourceTimer?
    private var sessionDetailRefreshTimer: DispatchSourceTimer?
    private var endpointURL: URL?
    private var endpointTrust: OuroborosEndpointTrust?
    private var endpointBearerToken: String?
    private var urlSession: URLSession?
    private var urlSessionDelegate: OuroborosHTTPDelegate?
    private var httpTasks: [Int: Task<Void, Never>] = [:]
    private var transportGeneration: UInt64 = 0
    private var initializeInFlight = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var targetRefreshInFlight = Set<String>()
    private var targetRefreshQueue: [String] = []
    private struct SessionStatusCandidate: Equatable {
        let sessionID: String
        let executionID: String
    }
    private var statusRefreshInFlight = Set<String>()
    private var statusRefreshQueue: [SessionStatusCandidate] = []
    private var statusRefreshChanged = false
    private var targetDiscoveryIntentGenerations: [String: UInt64] = [:]
    private var catalog = MCPSourceCatalog()
    private var negotiatedProtocolVersion: String?
    private var routingCapability: OuroborosRoutingCapability?
    private var routingBatch: OuroborosRoutingBatch?
    private var routingRefreshInFlight = false
    private var routingExpiryWorkItem: DispatchWorkItem?
    private var started = false
    private var connected = false
    private var observationActive = false
    private var observationGeneration: UInt64 = 0
    private var sharedServiceAwaitGeneration: UInt64 = 0
    private var requestedCollections = Set<MCPCollectionKind>()
    private var collectionLoads = Set<MCPCollectionKind>()
    private var activeSessionDetail: MCPSessionActivation?
    private struct SessionDetailLoad {
        let activation: MCPSessionActivation
        let observationGeneration: UInt64
        var pages: [OuroborosSessionDetailProjectionV0511.EventType:
            OuroborosSessionDetailProjectionV0511.Page]
        var projectionResolved: Bool
        var runProjection: OuroborosRunProjectionV0516.Snapshot?
    }
    private var sessionDetailLoad: SessionDetailLoad?
    private var activeSessionDetailSnapshot: OuroborosSessionDetailProjectionV0511.Snapshot?
    private var demoSessionDetailSequence = 0
    private lazy var sessionTimestampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private lazy var sessionTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
        return formatter
    }()
    private lazy var sessionNaiveTimestampParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter
    }()

    deinit {
        stop()
    }

    func start() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.startIfNeeded()
        }
    }

    func stop() {
        ioQueue.sync { [weak self] in
            guard let self else { return }
            self.observationActive = false
            self.started = false
            self.sharedServiceAwaitGeneration &+= 1
            self.cancelObservationWork(clearAuthority: true)
            self.resetHTTPTransport()
        }
    }

    func retry() {
        if let demoMode = LaunchConfiguration.demoMode {
            startDemo(mode: demoMode)
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            if self.connected, self.observationActive {
                self.refreshSessions()
                self.refreshRoutingSnapshot()
                for kind in self.requestedCollections { self.loadCollection(kind) }
            } else if self.endpointURL != nil {
                self.rebuildHTTPSession()
                self.initializeTransport()
            } else {
                if case .sharedDefault(let autoStart, _, _) = LaunchConfiguration.ouroborosSelection,
                   autoStart {
                    SharedOuroborosServiceRuntime.shared.retry()
                }
                self.started = false
                self.startIfNeeded()
            }
        }
    }

    func pauseObservation() {
        ioQueue.async { [weak self] in
            guard let self, self.observationActive else { return }
            self.observationActive = false
            self.observationGeneration &+= 1
            self.cancelObservationWork(clearAuthority: true)
        }
    }

    func resumeObservation() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.observationActive
            self.observationActive = true
            if !wasActive { self.observationGeneration &+= 1 }
            self.startIfNeeded()
            // Captured fanout fixtures publish their complete bounded
            // projection from `startDemo`. Do not let the production
            // 0.51.6 compact-session query overwrite that fixture with an
            // intentional version-mismatch error.
            if LaunchConfiguration.demoMode != nil { return }
            guard !wasActive, self.connected else { return }
            self.refreshSessions()
            self.refreshRoutingSnapshot()
            for kind in self.requestedCollections { self.loadCollection(kind) }
            self.startRefreshTimer()
        }
    }

    func requestCollection(_ kind: MCPCollectionKind) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.requestedCollections.insert(kind)
            guard self.observationActive, self.connected else { return }
            self.loadCollection(kind)
        }
    }

    func requestTargets(executionID: String, intentGeneration: UInt64?) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let intentGeneration {
                self.targetDiscoveryIntentGenerations[executionID] = intentGeneration
            }
            guard self.observationActive else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("Session observation is paused")
                )
                return
            }
            guard self.connected else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("Ouroboros is reconnecting")
                )
                return
            }
            guard OuroborosTargetOverlayTrustPolicy.permitsReadOnlyDiscovery(self.endpointTrust) else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("This MCP source cannot verify terminal targets")
                )
                return
            }
            guard self.groups.contains(where: { $0.executionID == executionID }) else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("That session is no longer available")
                )
                return
            }
            guard self.groups.contains(where: {
                $0.executionID == executionID
                    && SessionLifecycleCapabilityPolicy.isLive($0.status)
            }) else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .empty
                )
                return
            }
            // The loopback MCP bridge may disclose bounded live-attempt
            // identity and optional PTY correlation as read-only metadata.
            // It still cannot mint steering authority: `parseTarget` strips
            // delivery modes for this trust class and production `steer`
            // remains closed behind the broker-authenticated gateway.
            self.clearTargets(executionID: executionID)
            self.refreshTargets(executionID: executionID)
        }
    }

    func activateSession(_ activation: MCPSessionActivation) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.activeSessionDetail == activation {
                if LaunchConfiguration.demoMode == "fanout-8" {
                    self.publishDemoSessionDetail(activation)
                } else {
                    self.loadSessionDetail(activation, publishLoading: false)
                }
                return
            }
            self.stopSessionDetailRefreshTimer()
            self.activeSessionDetail = activation
            self.activeSessionDetailSnapshot = nil
            if LaunchConfiguration.demoMode == "fanout-8" {
                self.demoSessionDetailSequence = 0
                self.publishDemoSessionDetail(activation)
                self.startSessionDetailRefreshTimer()
                return
            }
            guard self.loadSessionDetail(activation, publishLoading: true) else { return }
            self.startSessionDetailRefreshTimer()
        }
    }

    func refreshSession(_ activation: MCPSessionActivation) {
        ioQueue.async { [weak self] in
            guard let self, self.activeSessionDetail == activation else { return }
            self.loadSessionDetail(activation, publishLoading: false)
        }
    }

    @discardableResult
    private func loadSessionDetail(
        _ activation: MCPSessionActivation,
        publishLoading: Bool
    ) -> Bool {
        guard activeSessionDetail == activation,
              observationActive,
              connected,
              sessionDetailLoad == nil else {
            if publishLoading, activeSessionDetailSnapshot == nil {
                publishSessionDetail(.unavailable(activation, "Ouroboros is reconnecting"))
            }
            return false
        }
        if activation.requiresExactAttempt, activation.attemptFilter == nil {
            if activeSessionDetailSnapshot == nil {
                publishSessionDetail(.unavailable(
                    activation,
                    OuroborosSessionDetailProjectionV0511.Failure.invalidIdentity.description
                ))
            }
            return false
        }
        guard OuroborosSessionDetailProjectionV0511.supports(
            serverName: catalog.serverName,
            serverVersion: catalog.serverVersion
        ), OuroborosSessionDetailProjectionV0511.toolArguments(
            sessionID: activation.sessionID,
            eventType: .sessionStarted,
            attemptFilter: activation.attemptFilter
        ) != nil else {
            if activeSessionDetailSnapshot == nil {
                publishSessionDetail(.unavailable(
                    activation,
                    OuroborosSessionDetailProjectionV0511.Failure.incompatibleServer.description
                ))
            }
            return false
        }
        if publishLoading { publishSessionDetail(.loading(activation)) }
        let observationGeneration = self.observationGeneration
        sessionDetailLoad = SessionDetailLoad(
            activation: activation,
            observationGeneration: observationGeneration,
            pages: [:],
            projectionResolved: false,
            runProjection: nil
        )
        for eventType in OuroborosSessionDetailProjectionV0511.EventType.allCases {
            guard let arguments = OuroborosSessionDetailProjectionV0511.toolArguments(
                sessionID: activation.sessionID,
                eventType: eventType,
                attemptFilter: activation.attemptFilter
            ) else { continue }
            request(
                method: "tools/call",
                params: [
                    "name": OuroborosSessionDetailProjectionV0511.toolName,
                    "arguments": arguments,
                ]
            ) { [weak self] response in
                self?.receiveSessionDetailPage(
                    response,
                    eventType: eventType,
                    activation: activation,
                    observationGeneration: observationGeneration
                )
            }
        }
        guard !activation.requiresExactAttempt,
              let projectionArguments = OuroborosRunProjectionV0516.toolArguments(
                sessionID: activation.sessionID,
                executionID: activation.executionID
              ) else {
            sessionDetailLoad?.projectionResolved = true
            finishSessionDetailIfReady(
                activation: activation,
                observationGeneration: observationGeneration
            )
            return true
        }
        request(
            method: "tools/call",
            params: [
                "name": OuroborosRunProjectionV0516.toolName,
                "arguments": projectionArguments,
            ]
        ) { [weak self] response in
            self?.receiveSessionRunProjection(
                response,
                activation: activation,
                observationGeneration: observationGeneration
            )
        }
        return true
    }

    private func startSessionDetailRefreshTimer() {
        guard activeSessionDetail != nil, observationActive, connected else { return }
        sessionDetailRefreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(
            deadline: .now() + Self.sessionDetailRefreshSeconds,
            repeating: Self.sessionDetailRefreshSeconds,
            leeway: .milliseconds(SessionStreamRefreshPolicy.leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            guard let self, let activation = self.activeSessionDetail else { return }
            if LaunchConfiguration.demoMode == "fanout-8" {
                self.publishDemoSessionDetail(activation)
            } else {
                self.loadSessionDetail(activation, publishLoading: false)
            }
        }
        timer.resume()
        sessionDetailRefreshTimer = timer
    }

    private func stopSessionDetailRefreshTimer() {
        sessionDetailRefreshTimer?.cancel()
        sessionDetailRefreshTimer = nil
    }
    private func publishDemoSessionDetail(_ activation: MCPSessionActivation) {
        guard activeSessionDetail == activation else { return }
        demoSessionDetailSequence = min(8, demoSessionDetailSequence + 1)
        var events: [OuroborosSessionDetailProjectionV0511.Event] = []
        for index in 0..<demoSessionDetailSequence {
            let summary: String
            if index == 0 {
                summary = "Session connected to its live event stream."
            } else {
                summary = "Agent \(index) completed a bounded verification update."
            }
            events.append(OuroborosSessionDetailProjectionV0511.Event(
                id: "demo-stream-\(activation.executionID)-\(index)",
                type: index == 0 ? .sessionStarted : .acCompleted,
                timestamp: String(format: "2026-08-21T00:00:%02dZ", index),
                aggregateType: index == 0 ? "session" : "execution",
                aggregateID: index == 0 ? activation.sessionID : activation.executionID,
                summary: summary
            ))
        }
        let snapshot = OuroborosSessionDetailProjectionV0511.Snapshot(
            sessionID: activation.sessionID,
            executionID: activation.executionID,
            attemptFilter: activation.attemptFilter,
            events: events,
            moreAvailable: false,
            runProjection: nil
        )
        guard SessionStreamRefreshPolicy.shouldPublish(
            previous: activeSessionDetailSnapshot,
            next: snapshot
        ) else { return }
        activeSessionDetailSnapshot = snapshot
        publishSessionDetail(.ready(activation, snapshot))
    }

    func deactivateSession(_ activation: MCPSessionActivation) {
        ioQueue.async { [weak self] in
            guard let self, self.activeSessionDetail == activation else { return }
            self.stopSessionDetailRefreshTimer()
            self.activeSessionDetail = nil
            self.activeSessionDetailSnapshot = nil
            self.sessionDetailLoad = nil
            self.publishSessionDetail(.idle)
        }
    }

    private func receiveSessionDetailPage(
        _ response: [String: Any],
        eventType: OuroborosSessionDetailProjectionV0511.EventType,
        activation: MCPSessionActivation,
        observationGeneration: UInt64
    ) {
        guard observationActive,
              self.observationGeneration == observationGeneration,
              activeSessionDetail == activation,
              var load = sessionDetailLoad,
              load.activation == activation,
              load.observationGeneration == observationGeneration else { return }
        switch OuroborosSessionDetailProjectionV0511.decodePage(
            response: response,
            sessionID: activation.sessionID,
            eventType: eventType,
            attemptFilter: activation.attemptFilter
        ) {
        case .failure(let failure):
            sessionDetailLoad = nil
            if activeSessionDetailSnapshot == nil {
                publishSessionDetail(.unavailable(activation, failure.description))
            }
        case .success(let page):
            guard load.pages[eventType] == nil else {
                sessionDetailLoad = nil
                if activeSessionDetailSnapshot == nil {
                    publishSessionDetail(.unavailable(
                        activation,
                        OuroborosSessionDetailProjectionV0511.Failure.duplicateEvent.description
                    ))
                }
                return
            }
            load.pages[eventType] = page
            sessionDetailLoad = load
            finishSessionDetailIfReady(
                activation: activation,
                observationGeneration: observationGeneration
            )
        }
    }

    private func receiveSessionRunProjection(
        _ response: [String: Any],
        activation: MCPSessionActivation,
        observationGeneration: UInt64
    ) {
        guard observationActive,
              self.observationGeneration == observationGeneration,
              activeSessionDetail == activation,
              var load = sessionDetailLoad,
              load.activation == activation,
              load.observationGeneration == observationGeneration,
              !load.projectionResolved else { return }
        if case .success(let projection) = OuroborosRunProjectionV0516.decode(
            response: response,
            sessionID: activation.sessionID,
            executionID: activation.executionID
        ) {
            load.runProjection = projection
        }
        load.projectionResolved = true
        sessionDetailLoad = load
        finishSessionDetailIfReady(activation: activation, observationGeneration: observationGeneration)
    }

    private func finishSessionDetailIfReady(
        activation: MCPSessionActivation,
        observationGeneration: UInt64
    ) {
        guard observationActive,
              self.observationGeneration == observationGeneration,
              activeSessionDetail == activation,
              let load = sessionDetailLoad,
              load.activation == activation,
              load.observationGeneration == observationGeneration,
              load.projectionResolved,
              load.pages.count == OuroborosSessionDetailProjectionV0511.EventType.allCases.count else {
            return
        }
        sessionDetailLoad = nil
        switch OuroborosSessionDetailProjectionV0511.build(
            pages: Array(load.pages.values),
            sessionID: activation.sessionID,
            executionID: activation.executionID,
            attemptFilter: activation.attemptFilter,
            runProjection: load.runProjection
        ) {
        case .success(let snapshot):
            guard SessionStreamRefreshPolicy.shouldPublish(
                previous: activeSessionDetailSnapshot,
                next: snapshot
            ) else { return }
            activeSessionDetailSnapshot = snapshot
            publishSessionDetail(.ready(activation, snapshot))
        case .failure(let failure):
            if activeSessionDetailSnapshot == nil {
                publishSessionDetail(.unavailable(activation, failure.description))
            }
        }
    }

    func steer(
        target: OuroborosSignalTarget,
        message: String,
        completion: @escaping (Result<OuroborosSteeringReceipt, Error>) -> Void
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(ClientError.invalidResponse("Steering message is empty")))
            return
        }
        guard target.modes.contains("after_turn") else {
            completion(.failure(ClientError.invalidResponse("This attempt does not advertise next-turn delivery")))
            return
        }
        if LaunchConfiguration.demoMode == "fanout-8" {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(240)) {
                completion(.success(OuroborosSteeringReceipt(
                    summary: "Queued for exact demo attempt · application not yet proven",
                    state: .queued,
                    applicationProven: false
                )))
            }
            return
        }
        if LaunchConfiguration.demoMode == "rejected" {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(240)) {
                completion(.failure(ClientError.invalidResponse("target_lost_before_delivery")))
            }
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.observationActive,
                  self.connected,
                  self.endpointTrust == .managedAuthenticated,
                  let token = self.endpointBearerToken,
                  SharedOuroborosBearerToken.isValid(token) else {
                return self.completeSteering(
                    completion,
                    .failure(ClientError.invalidResponse(
                        "Steering is read-only unless Ourocode owns an authenticated shared service"
                    ))
                )
            }
            guard self.groups.contains(where: { group in
                group.executionID == target.executionID && group.tabs.contains(where: {
                    $0.sessionIdentity == target.sessionIdentity && $0.target == target
                })
            }) else {
                return self.completeSteering(
                    completion,
                    .failure(ClientError.invalidResponse("That exact attempt is no longer active"))
                )
            }
            let steeringTarget = OuroborosSteeringTargetV1(
                executionID: target.executionID,
                scopeID: target.scopeID,
                attemptID: target.attemptID,
                contractVersion: target.contractVersion,
                modes: target.modes
            )
            guard let idempotencyKey = OuroborosAuthenticatedSteeringV1.idempotencyKey(
                target: steeringTarget,
                message: trimmed
            ), let arguments = OuroborosAuthenticatedSteeringV1.toolArguments(
                target: steeringTarget,
                message: trimmed,
                idempotencyKey: idempotencyKey
            ) else {
                return self.completeSteering(
                    completion,
                    .failure(ClientError.invalidResponse("The exact steering request is malformed"))
                )
            }
            self.request(
                method: "tools/call",
                params: [
                    "name": "ouroboros_session_signal",
                    "arguments": arguments,
                ]
            ) { [weak self] response in
                guard let self else { return }
                self.completeSteering(
                    completion,
                    self.toolResult(
                        response,
                        requestTarget: steeringTarget,
                        requestMessage: trimmed,
                        requestIdempotencyKey: idempotencyKey
                    )
                )
            }
        }
    }

    func refreshSteering(
        receipt: OuroborosSteeringReceipt,
        completion: @escaping (Result<OuroborosSteeringReceipt, Error>) -> Void
    ) {
        guard receipt.canRefreshLifecycle,
              let target = receipt.target,
              let message = receipt.message,
              let idempotencyKey = receipt.idempotencyKey,
              let arguments = OuroborosAuthenticatedSteeringV1.toolArguments(
                target: target,
                message: message,
                idempotencyKey: idempotencyKey
              ) else {
            completion(.failure(ClientError.invalidResponse(
                "This receipt does not contain a refreshable immutable request"
            )))
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.observationActive,
                  self.connected,
                  self.endpointTrust == .managedAuthenticated,
                  let token = self.endpointBearerToken,
                  SharedOuroborosBearerToken.isValid(token) else {
                return self.completeSteering(
                    completion,
                    .failure(ClientError.invalidResponse("Receipt refresh transport is unavailable"))
                )
            }
            // Ouroboros 0.51.6's mailbox returns the durable current projection
            // before active-target resolution once this signal has advanced
            // past requested. Replaying these exact arguments is therefore the
            // only safe lifecycle refresh on the current public MCP surface.
            self.request(
                method: "tools/call",
                params: [
                    "name": "ouroboros_session_signal",
                    "arguments": arguments,
                ]
            ) { [weak self] response in
                guard let self else { return }
                self.completeSteering(
                    completion,
                    self.toolResult(
                        response,
                        requestTarget: target,
                        requestMessage: message,
                        requestIdempotencyKey: idempotencyKey
                    )
                )
            }
        }
    }

    private func completeSteering(
        _ completion: @escaping (Result<OuroborosSteeringReceipt, Error>) -> Void,
        _ result: Result<OuroborosSteeringReceipt, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func startDemo(mode: String) {
        publishAuthenticatedSteering(.ready)
        publishRoutingState(.unavailable)
        catalog = MCPSourceCatalog(
            protocolVersion: "2025-06-18",
            serverName: "Ouroboros",
            serverVersion: "demo",
            endpoint: "Captured MCP v2 fixture · \(mode)",
            capabilities: ["resources", "tools"],
            toolsStatus: "2",
            resourcesStatus: "1",
            promptsStatus: "Unsupported",
            tools: [
                MCPBrowserEntry(id: "tool:ouroboros_session_signal", title: "ouroboros_session_signal", detail: "Guarded cross-session message delivery"),
                MCPBrowserEntry(id: "tool:ouroboros_session_signal_targets", title: "ouroboros_session_signal_targets", detail: "Exact live attempt discovery")
            ],
            resources: [
                MCPBrowserEntry(id: "resource:ouroboros://sessions", title: "Session index", detail: "Ouroboros execution and attempt projection")
            ],
            prompts: []
        )
        groups = (0..<2).map { groupIndex in
            let executionID = "demo-execution-\(groupIndex + 1)"
            let tabs = (0..<4).map { tabIndex -> OuroborosSessionTab in
                let index = groupIndex * 4 + tabIndex + 1
                let identity = OuroborosSessionAttemptIdentityV1(
                    sourceID: "ouroboros",
                    sessionID: "demo-session-\(groupIndex + 1)",
                    executionID: executionID,
                    scopeID: "demo-scope-\(index)",
                    attemptID: "demo-attempt-\(index)"
                )
                let target = OuroborosSignalTarget(
                    executionID: executionID,
                    scopeID: "demo-scope-\(index)",
                    attemptID: "demo-attempt-\(index)",
                    contractVersion: 1,
                    acID: "AC-\(index)",
                    nodeID: nil,
                    label: "Agent \(index)",
                    content: "Verify fanout worker \(index) and report a concise result.",
                    displayPath: "\(groupIndex + 1).\(tabIndex + 1)",
                    depth: 0,
                    modes: ["after_turn", "inform"],
                    sessionIdentity: identity
                )
                return OuroborosSessionTab(
                    id: "AC-\(index)",
                    label: "Agent \(index)",
                    detail: target.content,
                    status: mode == "ended" || index == 8 ? "completed" : "running",
                    depth: 0,
                    target: mode == "ended" || index == 8 ? nil : target,
                    sessionIdentity: identity
                )
            }
            return OuroborosSessionGroup(
                sessionID: "demo-session-\(groupIndex + 1)",
                executionID: executionID,
                title: groupIndex == 0 ? "Architecture and terminal core" : "MCP routing and product QA",
                status: mode == "ended" ? "completed" : "running",
                activity: "4 fanout attempts · captured fixture",
                suggestedTier: groupIndex == 0 ? "reasoning" : "fast",
                tabs: tabs
            )
        }
        publishCatalog()
        switch mode {
        case "offline":
            groups = []
            publishGroups()
            dispatchState(.offline(reason: "Captured broker unavailable state"))
        case "limited":
            publishGroups()
            dispatchState(.connected(version: "demo"))
            DispatchQueue.main.async { [weak self] in
                self?.onProjectionIssue?("Captured session projection timeout")
            }
        default:
            publishGroups()
            dispatchState(.connected(version: "demo"))
            DispatchQueue.main.async { [weak self] in self?.onProjectionIssue?(nil) }
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        if let demoMode = LaunchConfiguration.demoMode {
            startDemo(mode: demoMode)
            connected = true
            return
        }
        dispatchState(.starting)
        switch LaunchConfiguration.ouroborosSelection {
        case .disabled:
            dispatchState(.offline(reason: "Ouroboros connection disabled"))
        case .invalid(let reason):
            dispatchState(.offline(reason: reason))
        case .explicit(let url):
            configureEndpoint(url, trust: .explicitUserConfigured)
        case .sharedDefault(let autoStart, _, _):
            // AppDelegate may ask launchd to retain the audited shared service;
            // this client only attaches after that exact immutable contract is
            // ready and never owns or terminates it. Attach-only is an explicit
            // user choice and keeps the previous direct loopback behavior.
            guard autoStart else {
                configureEndpoint(LaunchConfiguration.sharedOuroborosEndpoint, trust: .localUnauthenticated)
                return
            }
            sharedServiceAwaitGeneration &+= 1
            let generation = sharedServiceAwaitGeneration
            SharedOuroborosServiceRuntime.shared.whenSettled { [weak self] result in
                self?.ioQueue.async { [weak self] in
                    guard let self,
                          self.started,
                          self.sharedServiceAwaitGeneration == generation else { return }
                    switch result {
                    case .success(let managedEndpoint):
                        self.configureEndpoint(
                            managedEndpoint.endpoint,
                            trust: .managedAuthenticated,
                            bearerToken: managedEndpoint.bearerToken
                        )
                    case .failure:
                        self.started = false
                        self.dispatchState(.offline(reason: "Shared Ouroboros could not start safely"))
                        guard self.observationActive, self.reconnectWorkItem == nil else { break }
                        let delay = min(TimeInterval(1 << min(self.reconnectAttempt, 4)), 15)
                        self.reconnectAttempt += 1
                        let work = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.ioQueue.async {
                                self.reconnectWorkItem = nil
                                guard self.observationActive else { return }
                                SharedOuroborosServiceRuntime.shared.retry()
                                self.startIfNeeded()
                            }
                        }
                        self.reconnectWorkItem = work
                        self.ioQueue.asyncAfter(deadline: .now() + delay, execute: work)
                }
                }
            }
            }
    }

    private func configureEndpoint(
        _ url: URL,
        trust: OuroborosEndpointTrust,
        bearerToken: String? = nil
    ) {
        if trust == .managedAuthenticated {
            guard url == SharedOuroborosResolver.defaultEndpoint,
                  let bearerToken,
                  SharedOuroborosBearerToken.isValid(bearerToken) else {
                endpointURL = nil
                endpointTrust = nil
                endpointBearerToken = nil
                started = false
                dispatchState(.offline(reason: "Shared Ouroboros authentication is invalid"))
                return
            }
        } else if bearerToken != nil {
            endpointURL = nil
            endpointTrust = nil
            endpointBearerToken = nil
            started = false
            dispatchState(.offline(reason: "Unmanaged MCP endpoints cannot receive shared credentials"))
            return
        }
        endpointURL = url
        endpointTrust = trust
        endpointBearerToken = bearerToken
        publishAuthenticatedSteering(.unavailable(reason: "Verifying authenticated MCP steering"))
        let trustLabel: String
        switch trust {
        case .managedAuthenticated: trustLabel = "managed authenticated"
        case .localUnauthenticated: trustLabel = "local unauthenticated"
        case .explicitUserConfigured: trustLabel = "explicit read-only"
        }
        catalog.endpoint = "\(url.absoluteString) · \(trustLabel)"
        rebuildHTTPSession()
        initializeTransport()
    }

    private func rebuildHTTPSession() {
        transportGeneration &+= 1
        cancelTargetDiscoveries(reason: "Terminal target check was cancelled")
        initializeInFlight = false
        negotiatedProtocolVersion = nil
        connected = false
        pending.removeAll(keepingCapacity: true)
        refreshInFlight = false
        targetRefreshInFlight.removeAll(keepingCapacity: true)
        targetRefreshQueue.removeAll(keepingCapacity: true)
        statusRefreshInFlight.removeAll(keepingCapacity: true)
        stopSessionDetailRefreshTimer()
        activeSessionDetailSnapshot = nil
        statusRefreshQueue.removeAll(keepingCapacity: true)
        statusRefreshChanged = false
        collectionLoads.removeAll(keepingCapacity: true)
        routingRefreshInFlight = false
        httpTasks.values.forEach { $0.cancel() }
        httpTasks.removeAll(keepingCapacity: true)
        urlSession?.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let delegate = OuroborosHTTPDelegate()
        urlSessionDelegate = delegate
        urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func resetHTTPTransport() {
        transportGeneration &+= 1
        cancelTargetDiscoveries(reason: "Terminal target check was cancelled")
        connected = false
        initializeInFlight = false
        negotiatedProtocolVersion = nil
        pending.removeAll(keepingCapacity: true)
        httpTasks.values.forEach { $0.cancel() }
        httpTasks.removeAll(keepingCapacity: true)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        urlSessionDelegate = nil
        endpointURL = nil
        endpointTrust = nil
        endpointBearerToken = nil
        publishAuthenticatedSteering(.unavailable(reason: "MCP transport is disconnected"))
    }

    private func cancelObservationWork(clearAuthority: Bool) {
        refreshTimer?.cancel()
        refreshTimer = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        targetRefreshQueue.removeAll(keepingCapacity: true)
        targetRefreshInFlight.removeAll(keepingCapacity: true)
        statusRefreshQueue.removeAll(keepingCapacity: true)
        statusRefreshInFlight.removeAll(keepingCapacity: true)
        statusRefreshChanged = false
        cancelTargetDiscoveries(reason: "Session observation stopped")
        refreshInFlight = false
        collectionLoads.removeAll(keepingCapacity: true)
        activeSessionDetail = nil
        sessionDetailLoad = nil
        routingRefreshInFlight = false
        routingExpiryWorkItem?.cancel()
        routingExpiryWorkItem = nil
        if clearAuthority {
            clearAllTargets()
            routingBatch = nil
            publishRoutingState(.unavailable)
        }
    }

    private func initializeTransport() {
        guard endpointURL != nil, urlSession != nil, !initializeInFlight else { return }
        initializeInFlight = true
        negotiatedProtocolVersion = nil
        request(
            method: "initialize",
            params: [
                "protocolVersion": OuroborosMCPProtocolVersion.preferred,
                "capabilities": [:],
                "clientInfo": ["name": "ourocode-desktop", "version": "0.1.0"]
            ]
        ) { [weak self] response in
            guard let self else { return }
            self.initializeInFlight = false
            if let error = response["error"] as? [String: Any] {
                self.scheduleReconnect(reason: error["message"] as? String ?? "MCP initialization failed")
                return
            }
            let result = response["result"] as? [String: Any]
            guard OuroborosMCPProtocolVersion.accepts(
                result?["protocolVersion"] as? String
            ) else {
                self.scheduleReconnect(reason: "MCP protocol negotiation failed")
                return
            }
            let serverInfo = result?["serverInfo"] as? [String: Any]
            let capabilities = result?["capabilities"] as? [String: Any] ?? [:]
            guard serverInfo?["name"] as? String == Self.expectedServerName,
                  serverInfo?["version"] as? String == Self.expectedServerVersion else {
                self.scheduleReconnect(reason: "MCP endpoint is not exact Ouroboros \(Self.expectedServerVersion)")
                return
            }
            let version = Self.expectedServerVersion
            self.catalog.protocolVersion = result?["protocolVersion"] as? String
                ?? OuroborosMCPProtocolVersion.preferred
            self.negotiatedProtocolVersion = self.catalog.protocolVersion
            self.catalog.serverName = serverInfo?["name"] as? String ?? "Ouroboros"
            self.catalog.serverVersion = version
            self.catalog.capabilities = capabilities.keys.sorted()
            self.catalog.toolsStatus = capabilities["tools"] == nil ? "Unsupported" : "Loading…"
            self.catalog.resourcesStatus = capabilities["resources"] == nil ? "Unsupported" : "Loading…"
            self.catalog.promptsStatus = capabilities["prompts"] == nil ? "Unsupported" : "Loading…"
            self.publishCatalog()
            self.connected = true
            if self.endpointTrust == .managedAuthenticated,
               let token = self.endpointBearerToken,
               SharedOuroborosBearerToken.isValid(token),
               capabilities["tools"] != nil {
                self.publishAuthenticatedSteering(.ready)
            } else {
                self.publishAuthenticatedSteering(.unavailable(
                    reason: "This endpoint is not an Ourocode-managed authenticated service"
                ))
            }
            self.reconnectAttempt = 0
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.notify(method: "notifications/initialized", params: [:])
            self.dispatchState(.connected(version: version))
            self.refreshCatalog(capabilities: capabilities)
            self.configureRoutingContract(capabilities: capabilities)
            if self.observationActive {
                for kind in self.requestedCollections { self.loadCollection(kind) }
            }
            if self.observationActive {
                self.refreshSessions()
                self.refreshRoutingSnapshot()
                self.startRefreshTimer()
            }
        }
    }

    private func refreshCatalog(capabilities: [String: Any]) {
        catalog.toolsStatus = capabilities["tools"] == nil ? "Unsupported" : "Available · expand to load"
        catalog.resourcesStatus = capabilities["resources"] == nil ? "Unsupported" : "Available · expand to load"
        catalog.promptsStatus = capabilities["prompts"] == nil ? "Unsupported" : "Available · expand to load"
        publishCatalog()
    }

    private func loadCollection(_ kind: MCPCollectionKind) {
        guard observationActive, connected, !collectionLoads.contains(kind) else { return }
        let catalogKind: CatalogKind
        switch kind {
        case .tools: catalogKind = .tools
        case .resources: catalogKind = .resources
        case .prompts: catalogKind = .prompts
        }
        let supported: Bool
        switch kind {
        case .tools: supported = catalog.toolsStatus != "Unsupported"
        case .resources: supported = catalog.resourcesStatus != "Unsupported"
        case .prompts: supported = catalog.promptsStatus != "Unsupported"
        }
        guard supported else { return }
        collectionLoads.insert(kind)
        loadCatalogPage(
            kind: catalogKind,
            cursor: nil,
            accumulated: [],
            observationGeneration: observationGeneration
        )
    }

    private func loadCatalogPage(
        kind: CatalogKind,
        cursor: String?,
        accumulated: [MCPBrowserEntry],
        observationGeneration: UInt64
    ) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        request(method: kind.method, params: params) { [weak self] response in
            guard let self else { return }
            guard self.observationActive,
                  self.observationGeneration == observationGeneration else {
                return
            }
            guard response["error"] == nil,
                  let result = response["result"] as? [String: Any],
                  let values = result[kind.resultKey] as? [[String: Any]] else {
                self.collectionLoads.remove(kind.collectionKind)
                self.setCatalog(kind: kind, entries: accumulated, status: "Unavailable · \(self.responseError(response) ?? "invalid response")")
                return
            }
            let remaining = max(0, 512 - accumulated.count)
            let page = values.prefix(remaining).compactMap { self.parseCatalogEntry($0, kind: kind) }
            let combined = accumulated + page
            let nextCursor = result["nextCursor"] as? String
            if let nextCursor, !nextCursor.isEmpty, combined.count < 512 {
                self.loadCatalogPage(
                    kind: kind,
                    cursor: nextCursor,
                    accumulated: combined,
                    observationGeneration: observationGeneration
                )
            } else {
                self.collectionLoads.remove(kind.collectionKind)
                let status: String
                if nextCursor?.isEmpty == false || values.count > remaining {
                    status = "512 shown · more available"
                } else if combined.isEmpty {
                    status = "Empty"
                } else {
                    status = "\(combined.count)"
                }
                self.setCatalog(kind: kind, entries: combined, status: status)
            }
        }
    }

    private func parseCatalogEntry(_ value: [String: Any], kind: CatalogKind) -> MCPBrowserEntry? {
        switch kind {
        case .tools, .prompts:
            guard let name = value["name"] as? String else { return nil }
            return MCPBrowserEntry(
                id: "\(kind.idPrefix):\(name)",
                title: name,
                detail: bounded(value["description"] as? String ?? kind.fallbackDetail, limit: 240)
            )
        case .resources:
            guard let uri = value["uri"] as? String else { return nil }
            return MCPBrowserEntry(
                id: "resource:\(uri)",
                title: value["name"] as? String ?? uri,
                detail: bounded(value["description"] as? String ?? uri, limit: 240)
            )
        }
    }

    private func setCatalog(kind: CatalogKind, entries: [MCPBrowserEntry], status: String) {
        switch kind {
        case .tools:
            catalog.tools = entries
            catalog.toolsStatus = status
        case .resources:
            catalog.resources = entries
            catalog.resourcesStatus = status
        case .prompts:
            catalog.prompts = entries
            catalog.promptsStatus = status
        }
        publishCatalog()
    }

    private func startRefreshTimer() {
        guard observationActive, connected else { return }
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        // The 0.51.6 compatibility index reads only two bounded lifecycle
        // event streams. It is cheap enough to refresh alongside routing while
        // the source is visible; pauseObservation cancels both.
        timer.schedule(
            deadline: .now() + Self.snapshotRefreshSeconds,
            repeating: Self.snapshotRefreshSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.refreshSessions()
            self?.refreshRoutingSnapshot()
        }
        timer.resume()
        refreshTimer = timer
    }

    private func scheduleReconnect(reason: String) {
        connected = false
        negotiatedProtocolVersion = nil
        routingCapability = nil
        routingBatch = nil
        routingRefreshInFlight = false
        routingExpiryWorkItem?.cancel()
        routingExpiryWorkItem = nil
        publishRoutingState(.unavailable)
        publishAuthenticatedSteering(.unavailable(reason: "Authenticated MCP connection was lost"))
        dispatchState(.offline(reason: reason))
        guard observationActive, endpointURL != nil, reconnectWorkItem == nil else { return }
        let exponent = min(reconnectAttempt, 5)
        let delay = min(TimeInterval(1 << exponent), 30)
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.rebuildHTTPSession()
            self.initializeTransport()
        }
        reconnectWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshSessions() {
        guard observationActive,
              connected,
              !refreshInFlight,
              targetRefreshInFlight.isEmpty,
              targetRefreshQueue.isEmpty,
              statusRefreshInFlight.isEmpty,
              statusRefreshQueue.isEmpty else { return }
        guard OuroborosCompactSessionIndexV0511.supports(
            serverName: catalog.serverName,
            serverVersion: catalog.serverVersion
        ) else {
            let handler = onProjectionIssue
            DispatchQueue.main.async {
                handler?(OuroborosCompactSessionIndexV0511.Failure.incompatibleServer.description)
            }
            return
        }
        refreshInFlight = true
        let refreshObservationGeneration = observationGeneration
        // The compact session index and exact target discovery have separate
        // lifetimes. Preserve the snapshot for the multiplexer the user has
        // explicitly opened; erasing it on every metadata poll makes a live
        // session view-only while the user is typing. It is revalidated after
        // authoritative status hydration below, and any empty/failed target
        // response still revokes the complete snapshot fail-closed.
        clearAllTargets(preservingExecutionID: activeSessionDetail?.executionID)
        loadCompactSessionPage(
            eventTypeIndex: 0,
            offset: 0,
            events: [],
            eventIDs: [],
            observationGeneration: refreshObservationGeneration
        )
    }

    private func loadCompactSessionPage(
        eventTypeIndex: Int,
        offset: Int,
        events: [OuroborosCompactSessionIndexV0511.Event],
        eventIDs: Set<String>,
        observationGeneration: UInt64
    ) {
        guard observationActive,
              connected,
              self.observationGeneration == observationGeneration else { return }
        let eventTypes = OuroborosCompactSessionIndexV0511.EventType.allCases
        guard eventTypeIndex < eventTypes.count else {
            finishCompactSessionRefresh(events: events, observationGeneration: observationGeneration)
            return
        }

        let eventType = eventTypes[eventTypeIndex]
        // One final one-row probe at offset 4096 distinguishes an exact-cap
        // result from a silently truncated index. A non-empty probe fails
        // closed; the client never publishes a misleading partial prefix.
        let limit = offset == OuroborosCompactSessionIndexV0511.maximumEventsPerType
            ? 1
            : min(
                OuroborosCompactSessionIndexV0511.pageSize,
                OuroborosCompactSessionIndexV0511.maximumEventsPerType - offset
            )
        guard let arguments = OuroborosCompactSessionIndexV0511.toolArguments(
            eventType: eventType,
            offset: offset,
            limit: limit
        ) else {
            failCompactSessionRefresh(
                .mismatchedPage,
                observationGeneration: observationGeneration
            )
            return
        }
        request(
            method: "tools/call",
            params: [
                "name": OuroborosCompactSessionIndexV0511.toolName,
                "arguments": arguments,
            ]
        ) { [weak self] response in
            guard let self,
                  self.observationActive,
                  self.connected,
                  self.observationGeneration == observationGeneration else { return }
            switch OuroborosCompactSessionIndexV0511.decodePage(
                response: response,
                eventType: eventType,
                offset: offset,
                limit: limit
            ) {
            case .failure(let failure):
                self.failCompactSessionRefresh(failure, observationGeneration: observationGeneration)
            case .success(let page):
                if offset == OuroborosCompactSessionIndexV0511.maximumEventsPerType {
                    guard page.events.isEmpty else {
                        self.failCompactSessionRefresh(
                            .capacityExceeded,
                            observationGeneration: observationGeneration
                        )
                        return
                    }
                    self.loadCompactSessionPage(
                        eventTypeIndex: eventTypeIndex + 1,
                        offset: 0,
                        events: events,
                        eventIDs: eventIDs,
                        observationGeneration: observationGeneration
                    )
                    return
                }

                var nextEventIDs = eventIDs
                for event in page.events where !nextEventIDs.insert(event.id).inserted {
                    self.failCompactSessionRefresh(
                        .duplicateEvent,
                        observationGeneration: observationGeneration
                    )
                    return
                }
                let nextEvents = events + page.events
                if page.events.count == limit {
                    self.loadCompactSessionPage(
                        eventTypeIndex: eventTypeIndex,
                        offset: offset + page.events.count,
                        events: nextEvents,
                        eventIDs: nextEventIDs,
                        observationGeneration: observationGeneration
                    )
                } else {
                    self.loadCompactSessionPage(
                        eventTypeIndex: eventTypeIndex + 1,
                        offset: 0,
                        events: nextEvents,
                        eventIDs: nextEventIDs,
                        observationGeneration: observationGeneration
                    )
                }
            }
        }
    }

    private func finishCompactSessionRefresh(
        events: [OuroborosCompactSessionIndexV0511.Event],
        observationGeneration: UInt64
    ) {
        guard observationActive,
              connected,
              self.observationGeneration == observationGeneration else { return }
        switch OuroborosCompactSessionIndexV0511.build(events: events) {
        case .failure(let failure):
            failCompactSessionRefresh(failure, observationGeneration: observationGeneration)
        case .success(let sessions):
            refreshInFlight = false
            let candidates = Array(
                sessions.lazy
                    .filter { $0.status == "running" }
                    .prefix(Self.maximumStatusCandidates)
                    .map { SessionStatusCandidate(sessionID: $0.sessionID, executionID: $0.executionID) }
            )
            let candidateSessionIDs = Set(candidates.map(\.sessionID))
            let parsed = sessions.map { session in
                let countDetail = session.messagesProcessed.map { "\($0) messages" } ?? "No messages yet"
                // A compact-index refresh is metadata only. If the user has
                // an open multiplexer, carry its last verified exact-target
                // snapshot into the new group object until the independent
                // target response replaces it. Building `tabs: []` here
                // silently turned an actively steerable run back into a
                // read-only "Finding live agents" row every polling tick.
                let retainedTabs: [OuroborosSessionTab] = {
                    guard OuroborosActiveTargetRefreshPolicy.preservesSnapshot(
                        executionID: session.executionID,
                        activeExecutionID: activeSessionDetail?.executionID
                    ) else { return [] }
                    return groups.first(where: {
                        $0.sessionID == session.sessionID
                            && $0.executionID == session.executionID
                    })?.tabs ?? []
                }()
                return OuroborosSessionGroup(
                    sessionID: session.sessionID,
                    executionID: session.executionID,
                    title: displaySessionTitle(
                        session.executionID,
                        lastActivityAt: session.lastActivityAt
                    ),
                    // Missing terminal events do not prove that a session is
                    // still live. Only a bounded authoritative status query
                    // may promote a recent candidate into Live sessions.
                    status: session.status == "running"
                        ? (candidateSessionIDs.contains(session.sessionID) ? "checking" : "unknown")
                        : session.status,
                    activity: bounded(
                        "\(countDetail) · \(displaySessionTimestamp(session.lastActivityAt))",
                        limit: 120
                    ),
                    suggestedTier: nil,
                    tabs: retainedTabs
                )
            }
            let handler = onProjectionIssue
            DispatchQueue.main.async { handler?(nil) }
            if parsed != groups {
                groups = parsed
                publishGroups()
            }
            statusRefreshQueue = candidates
            statusRefreshChanged = false
            pumpStatusRefreshQueue(observationGeneration: observationGeneration)
            // Compact metadata is read-only. Exact steering authority remains
            // an explicit per-execution target discovery request.
            targetRefreshQueue.removeAll(keepingCapacity: true)
        }
    }

    private func pumpStatusRefreshQueue(observationGeneration: UInt64) {
        guard observationActive,
              connected,
              self.observationGeneration == observationGeneration else {
            statusRefreshQueue.removeAll(keepingCapacity: true)
            statusRefreshInFlight.removeAll(keepingCapacity: true)
            return
        }
        while statusRefreshInFlight.count < Self.maximumConcurrentStatusRefreshes,
              !statusRefreshQueue.isEmpty {
            let candidate = statusRefreshQueue.removeFirst()
            guard statusRefreshInFlight.insert(candidate.sessionID).inserted else { continue }
            request(
                method: "tools/call",
                params: [
                    "name": "ouroboros_session_status",
                    "arguments": ["session_id": candidate.sessionID],
                ]
            ) { [weak self] response in
                guard let self else { return }
                self.statusRefreshInFlight.remove(candidate.sessionID)
                guard self.observationActive,
                      self.connected,
                      self.observationGeneration == observationGeneration else { return }
                let status = self.decodeAuthoritativeSessionStatus(
                    response,
                    candidate: candidate
                ) ?? "unknown"
                if let index = self.groups.firstIndex(where: {
                    $0.sessionID == candidate.sessionID && $0.executionID == candidate.executionID
                }), self.groups[index].status != status {
                    self.groups[index].status = status
                    for tabIndex in self.groups[index].tabs.indices {
                        self.groups[index].tabs[tabIndex].status = status
                        if SessionLifecycleCapabilityPolicy.shouldRevokeInteractiveMetadata(
                            authoritativeStatus: status
                        ) {
                            self.groups[index].tabs[tabIndex].target = nil
                            self.groups[index].tabs[tabIndex].surface = .unbound(.notAdvertised)
                        }
                    }
                    self.statusRefreshChanged = true
                }
                self.pumpStatusRefreshQueue(observationGeneration: observationGeneration)
            }
        }
        if statusRefreshQueue.isEmpty,
           statusRefreshInFlight.isEmpty {
            if statusRefreshChanged {
                statusRefreshChanged = false
                publishGroups()
            }
            revalidateActiveTargetsIfNeeded()
        }
    }

    private func revalidateActiveTargetsIfNeeded() {
        guard let activeExecutionID = activeSessionDetail?.executionID,
              let group = groups.first(where: { $0.executionID == activeExecutionID }),
              OuroborosActiveTargetRefreshPolicy.shouldRevalidate(
                executionID: group.executionID,
                activeExecutionID: activeExecutionID,
                sessionIsLive: SessionLifecycleCapabilityPolicy.isLive(group.status)
              ) else { return }
        refreshTargets(executionID: activeExecutionID)
    }

    private func decodeAuthoritativeSessionStatus(
        _ response: [String: Any],
        candidate: SessionStatusCandidate
    ) -> String? {
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              result["isError"] as? Bool != true,
              let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              text.utf8.count <= Self.maximumStatusResponseTextBytes,
              let meta = (result["_meta"] as? [String: Any]) ?? (result["meta"] as? [String: Any]),
              meta["session_id"] as? String == candidate.sessionID,
              meta["execution_id"] as? String == candidate.executionID,
              let status = meta["status"] as? String else { return nil }
        let normalized = status.lowercased()
        return ["running", "active", "paused", "completed", "failed", "cancelled"]
            .contains(normalized) ? normalized : nil
    }

    private func displaySessionTitle(_ executionID: String, lastActivityAt: String) -> String {
        if executionID.hasPrefix("evolve:"),
           let generationRange = executionID.range(of: ":generation:") {
            let rawGoal = String(
                executionID[executionID.index(executionID.startIndex, offsetBy: 7)..<generationRange.lowerBound]
            )
            let generation = executionID[generationRange.upperBound...]
            let datedSuffix = rawGoal.suffix(9)
            let goal = datedSuffix.first == "-"
                && datedSuffix.dropFirst().allSatisfy(\.isNumber)
                ? String(rawGoal.dropLast(9))
                : rawGoal
            if !goal.isEmpty, !generation.isEmpty {
                return bounded("Gen \(generation) · \(goal)", limit: 96)
            }
        }
        return "Session · \(displaySessionTimestamp(lastActivityAt))"
    }

    private func displaySessionTimestamp(_ value: String) -> String {
        guard let date = sessionTimestampParser.date(from: value)
            ?? sessionNaiveTimestampParser.date(from: value) else { return value }
        return sessionTimestampFormatter.string(from: date)
    }

    private func failCompactSessionRefresh(
        _ failure: OuroborosCompactSessionIndexV0511.Failure,
        observationGeneration: UInt64
    ) {
        guard self.observationGeneration == observationGeneration else { return }
        refreshInFlight = false
        clearAllTargets()
        let handler = onProjectionIssue
        DispatchQueue.main.async { handler?(failure.description) }
    }

    private func configureRoutingContract(capabilities: [String: Any]) {
        routingBatch = nil
        routingRefreshInFlight = false
        routingExpiryWorkItem?.cancel()
        routingExpiryWorkItem = nil
        switch OuroborosRoutingCapability.negotiate(capabilities: capabilities) {
        case .unavailable:
            routingCapability = nil
            publishRoutingState(.unavailable)
        case .rejected(let failure):
            routingCapability = nil
            publishRoutingState(.rejected(failure))
        case .available(let capability):
            routingCapability = capability
            publishRoutingState(.loading)
            if observationActive { refreshRoutingSnapshot() }
        }
    }

    /// Fetches only an Ouroboros-advertised, cursor-bounded signed snapshot.
    /// This path never reads terminal input and never asks the desktop client
    /// to infer a tier or choose a provider.
    private func refreshRoutingSnapshot() {
        guard observationActive,
              connected,
              let capability = routingCapability,
              !routingRefreshInFlight else { return }
        routingRefreshInFlight = true
        let refreshObservationGeneration = observationGeneration
        let requestedCursor = routingBatch?.nextCursor ?? routingBatch?.cursor
        var arguments: [String: Any] = ["maximum_records": capability.maximumRecords]
        if let requestedCursor {
            arguments["cursor"] = requestedCursor
        }
        if let generation = routingBatch?.generation {
            arguments["minimum_generation"] = generation
        }
        request(
            method: "tools/call",
            params: ["name": capability.snapshotTool, "arguments": arguments]
        ) { [weak self] response in
            guard let self else { return }
            guard self.observationActive,
                  self.connected,
                  self.observationGeneration == refreshObservationGeneration else { return }
            self.routingRefreshInFlight = false
            guard response["error"] == nil,
                  let result = response["result"] as? [String: Any],
                  result["isError"] as? Bool != true,
                  let content = result["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                  let data = text.data(using: .utf8) else {
                self.routingBatch = nil
                self.routingExpiryWorkItem?.cancel()
                self.routingExpiryWorkItem = nil
                self.publishRoutingState(.rejected(.malformedEnvelope))
                return
            }
            let expectation = OuroborosRoutingDecodeExpectation(
                minimumGeneration: self.routingBatch?.generation,
                requestedCursor: requestedCursor
            )
            switch OuroborosRoutingReceiptDecoder(capability: capability).decode(data, expectation: expectation) {
            case .failure(let failure):
                // Never retain a stale receipt after any trust, generation, or
                // cursor failure. Recovery must begin from a fresh snapshot.
                self.routingBatch = nil
                self.routingExpiryWorkItem?.cancel()
                self.routingExpiryWorkItem = nil
                self.publishRoutingState(.rejected(failure))
            case .success(let batch):
                self.routingBatch = batch
                self.publishRoutingState(.ready(batch))
                self.scheduleRoutingExpiry(for: batch)
            }
        }
    }

    private func scheduleRoutingExpiry(for batch: OuroborosRoutingBatch) {
        routingExpiryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.routingBatch?.generation == batch.generation,
                  self.routingBatch?.cursor == batch.cursor,
                  self.routingBatch?.expiresAt == batch.expiresAt else { return }
            self.routingBatch = nil
            self.routingExpiryWorkItem = nil
            self.publishRoutingState(.rejected(.expired))
        }
        routingExpiryWorkItem = work
        ioQueue.asyncAfter(
            deadline: .now() + max(0, batch.expiresAt.timeIntervalSinceNow),
            execute: work
        )
    }

    private func refreshTargets(executionID: String) {
        guard observationActive,
              connected,
              !targetRefreshInFlight.contains(executionID),
              !targetRefreshQueue.contains(executionID) else { return }
        guard targetRefreshInFlight.count < Self.maximumConcurrentTargetRefreshes else {
            targetRefreshQueue.append(executionID)
            return
        }
        startTargetRefresh(executionID: executionID)
    }

    private func startTargetRefresh(executionID: String) {
        guard targetRefreshInFlight.insert(executionID).inserted else { return }
        let refreshObservationGeneration = observationGeneration
        request(
            method: "tools/call",
            params: [
                "name": "ouroboros_session_signal_targets",
                "arguments": ["execution_id": executionID]
            ]
        ) { [weak self] response in
            guard let self else { return }
            guard self.observationActive,
                  self.connected,
                  self.observationGeneration == refreshObservationGeneration else { return }
            self.targetRefreshInFlight.remove(executionID)
            defer { self.pumpTargetRefreshQueue() }
            guard let result = response["result"] as? [String: Any],
                  let meta = (result["_meta"] as? [String: Any]) ?? (result["meta"] as? [String: Any]),
                  let rawTargets = meta["targets"] as? [[String: Any]] else {
                self.clearTargets(executionID: executionID)
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable(self.responseError(response) ?? "Target discovery returned no usable result")
                )
                return
            }
            guard let groupIndex = self.groups.firstIndex(where: { $0.executionID == executionID }) else {
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("That session ended during target discovery")
                )
                return
            }
            let group = self.groups[groupIndex]
            guard SessionLifecycleCapabilityPolicy.isLive(group.status) else {
                self.clearTargets(executionID: executionID)
                self.finishTargetDiscovery(executionID: executionID, outcome: .empty)
                return
            }
            let parsedTargets = rawTargets.prefix(256).compactMap {
                self.parseTarget(
                    $0,
                    sessionID: group.sessionID,
                    expectedExecutionID: executionID
                )
            }
            let keyedTargets = parsedTargets.compactMap { target in
                target.sessionIdentity.map { (identity: $0, target: target) }
            }
            let targets: [OuroborosSignalTarget]
            switch OuroborosSessionTargetSnapshotPolicy.deduplicated(keyedTargets) {
            case .failure:
                // The response is one externally-owned snapshot. Publishing
                // either payload for one exact identity would guess authority,
                // so revoke the entire discovered generation.
                self.clearTargets(executionID: executionID)
                self.finishTargetDiscovery(
                    executionID: executionID,
                    outcome: .unavailable("Target discovery returned conflicting duplicate attempt identities")
                )
                return
            case .success(let deduplicated):
                targets = deduplicated
            }
            self.replaceDiscoveredTargets(
                executionID: executionID,
                targets: targets
            )
            self.finishTargetDiscovery(
                executionID: executionID,
                outcome: targets.isEmpty ? .empty : .discovered(targets.count)
            )
        }
    }

    private func finishTargetDiscovery(
        executionID: String,
        outcome: MCPSessionTargetDiscoveryOutcome
    ) {
        guard let intentGeneration = targetDiscoveryIntentGenerations.removeValue(forKey: executionID) else { return }
        let result = MCPSessionTargetDiscoveryResult(
            executionID: executionID,
            intentGeneration: intentGeneration,
            outcome: outcome
        )
        let handler = onTargetDiscovery
        DispatchQueue.main.async { handler?(result) }
    }

    private func cancelTargetDiscoveries(reason: String) {
        let pending = targetDiscoveryIntentGenerations
        targetDiscoveryIntentGenerations.removeAll(keepingCapacity: true)
        let handler = onTargetDiscovery
        for (executionID, intentGeneration) in pending {
            let result = MCPSessionTargetDiscoveryResult(
                executionID: executionID,
                intentGeneration: intentGeneration,
                outcome: .unavailable(reason)
            )
            DispatchQueue.main.async { handler?(result) }
        }
    }

    private func pumpTargetRefreshQueue() {
        while targetRefreshInFlight.count < Self.maximumConcurrentTargetRefreshes,
              !targetRefreshQueue.isEmpty {
            let executionID = targetRefreshQueue.removeFirst()
            if !targetRefreshInFlight.contains(executionID) {
                startTargetRefresh(executionID: executionID)
            }
        }
    }

    private func clearTargets(executionID: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.executionID == executionID }) else { return }
        var group = groups[groupIndex]
        let baseTabs = baseTabsRevokingTargetOverlays(group.tabs)
        guard baseTabs != group.tabs else { return }
        group.tabs = baseTabs
        groups[groupIndex] = group
        publishGroups()
    }

    private func clearAllTargets(preservingExecutionID activeExecutionID: String? = nil) {
        var changed = false
        for groupIndex in groups.indices {
            if OuroborosActiveTargetRefreshPolicy.preservesSnapshot(
                executionID: groups[groupIndex].executionID,
                activeExecutionID: activeExecutionID
            ) {
                continue
            }
            let baseTabs = baseTabsRevokingTargetOverlays(groups[groupIndex].tabs)
            if baseTabs != groups[groupIndex].tabs {
                groups[groupIndex].tabs = baseTabs
                changed = true
            }
        }
        if changed { publishGroups() }
    }

    /// Replaces the complete discovered-attempt suffix for one execution.
    /// Persisted/base rows are not discovery records: retain their labels and
    /// lifecycle data while revoking only their externally supplied overlay.
    private func replaceDiscoveredTargets(
        executionID: String,
        targets: [OuroborosSignalTarget]
    ) {
        guard let groupIndex = groups.firstIndex(where: { $0.executionID == executionID }) else { return }
        var group = groups[groupIndex]
        var tabs = baseTabsRevokingTargetOverlays(group.tabs)
        tabs.reserveCapacity(tabs.count + targets.count)
        for target in targets {
            guard let identity = target.sessionIdentity else { continue }
            tabs.append(OuroborosSessionTab(
                id: OuroborosSessionTerminalIdentityDecoderV1.stableTabID(for: identity),
                label: target.label,
                detail: target.content,
                status: group.status,
                depth: target.depth,
                target: target,
                sessionIdentity: identity,
                surface: target.surface
            ))
        }
        guard tabs != group.tabs else { return }
        group.tabs = tabs
        groups[groupIndex] = group
        publishGroups()
    }

    private func baseTabsRevokingTargetOverlays(
        _ tabs: [OuroborosSessionTab]
    ) -> [OuroborosSessionTab] {
        tabs.compactMap { existing in
            // Every row created by target discovery uses the framed stable
            // attempt id. It belongs to the response snapshot and must not
            // survive an empty, failed, malformed, or superseding refresh.
            guard !OuroborosSessionTargetSnapshotPolicy.isDiscoveredAttemptID(existing.id) else {
                return nil
            }
            var base = existing
            _ = OuroborosSessionTargetOverlayPolicy.revoke(
                target: &base.target,
                identity: &base.sessionIdentity,
                surface: &base.surface
            )
            return base
        }
    }

    private func parseTarget(
        _ value: [String: Any],
        sessionID: String,
        expectedExecutionID: String
    ) -> OuroborosSignalTarget? {
        guard let identity = OuroborosSessionTerminalIdentityDecoderV1.identity(
            sourceID: "ouroboros",
            sessionID: sessionID,
            expectedExecutionID: expectedExecutionID,
            target: value
        ) else { return nil }
        let capabilities = value["capabilities"] as? [String: Any] ?? [:]
        var modes = Set<String>()
        if OuroborosTargetOverlayTrustPolicy.permitsAdvertisedDeliveryModes(endpointTrust) {
            if capabilities["after_turn_delivery"] as? Bool == true { modes.insert("after_turn") }
            if capabilities["inform_delivery"] as? Bool == true { modes.insert("inform") }
            if capabilities["checkpoint_redirect"] as? Bool == true { modes.insert("redirect") }
            if capabilities["owned_turn_abort"] as? Bool == true,
               capabilities["replacement_resume"] as? Bool == true { modes.insert("replace") }
        }
        let content = value["ac_content"] as? String ?? "Active attempt"
        return OuroborosSignalTarget(
            executionID: identity.executionID,
            scopeID: identity.scopeID,
            attemptID: identity.attemptID,
            contractVersion: value["contract_version"] as? Int,
            acID: value["ac_id"] as? String,
            nodeID: value["node_id"] as? String,
            label: bounded(value["display_label"] as? String ?? value["display_path"] as? String ?? content, limit: 80),
            content: bounded(content, limit: 400),
            displayPath: value["display_path"] as? String,
            depth: value["depth"] as? Int ?? 0,
            modes: modes,
            sessionIdentity: identity,
            surface: OuroborosSessionTerminalIdentityDecoderV1.surface(
                target: value,
                identity: identity
            )
        )
    }

    private func toolResult(
        _ response: [String: Any],
        requestTarget: OuroborosSteeringTargetV1,
        requestMessage: String,
        requestIdempotencyKey: String
    ) -> Result<OuroborosSteeringReceipt, Error> {
        if let error = response["error"] as? [String: Any] {
            return .failure(ClientError.invalidResponse(error["message"] as? String ?? "MCP error"))
        }
        guard let result = response["result"] as? [String: Any] else {
            return .failure(ClientError.invalidResponse("Missing MCP tool result"))
        }
        let content = result["content"] as? [[String: Any]]
        let text = content?.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        let meta = result["_meta"] as? [String: Any]
            ?? result["meta"] as? [String: Any]
            ?? [:]
        // Structured rejected/uncertain receipts are authoritative lifecycle
        // outcomes, even though MCP marks them as tool errors. Preserve them
        // so the UI can show the terminal state instead of flattening it into
        // an uncorrelated transport failure.
        if result["isError"] as? Bool == true,
           meta["signal_id"] as? String == nil,
           meta["state"] as? String == nil {
            return .failure(ClientError.invalidResponse(text ?? "Ouroboros rejected the signal"))
        }
        let receipt = OuroborosSteeringReceiptDecoder.decode(
            result: result,
            summary: text ?? "Signal queued; application is not yet proven.",
            requestTarget: requestTarget,
            requestMessage: requestMessage,
            requestIdempotencyKey: requestIdempotencyKey
        )
        guard receipt.idempotencyKey == requestIdempotencyKey,
              meta["expected_execution_id"] as? String == requestTarget.executionID,
              meta["target_session_scope_id"] as? String == requestTarget.scopeID,
              meta["target_session_attempt_id"] as? String == requestTarget.attemptID else {
            return .failure(ClientError.invalidResponse(
                "Ouroboros returned a receipt for a different steering request"
            ))
        }
        return .success(receipt)
    }

    private func responseError(_ response: [String: Any]) -> String? {
        guard let error = response["error"] as? [String: Any] else { return nil }
        return bounded(error["message"] as? String ?? "MCP request failed", limit: 160)
    }

    private func publishGroups() {
        let snapshot = groups
        let handler = onSessionsChange
        DispatchQueue.main.async { handler?(snapshot) }
    }

    private func dispatchState(_ state: OuroborosConnectionState) {
        if case .offline = state {
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.clearAllTargets()
                self.routingBatch = nil
                self.routingExpiryWorkItem?.cancel()
                self.routingExpiryWorkItem = nil
                self.publishRoutingState(.unavailable)
            }
        }
        let handler = onStateChange
        DispatchQueue.main.async { handler?(state) }
    }

    private func publishCatalog() {
        let snapshot = catalog
        let handler = onCatalogChange
        DispatchQueue.main.async { handler?(snapshot) }
    }

    private func publishRoutingState(_ state: OuroborosRoutingContractState) {
        let handler = onRoutingContractChange
        DispatchQueue.main.async { handler?(state) }
    }

    private func publishSessionDetail(_ state: MCPSessionDetailState) {
        let handler = onSessionDetailChange
        DispatchQueue.main.async { handler?(state) }
    }

    private func publishAuthenticatedSteering(_ state: MCPAuthenticatedSteeringState) {
        let handler = onAuthenticatedSteeringChange
        DispatchQueue.main.async { handler?(state) }
    }

    private func request(method: String, params: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        requestID += 1
        let id = requestID
        pending[id] = PendingRequest(generation: transportGeneration, completion: completion)
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(method: String, params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let endpointURL,
              let urlSession else { return }
        let generation = transportGeneration
        let expectedID = object["id"] as? Int
        let method = object["method"] as? String ?? "unknown"
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        guard OuroborosRequestAuthorizationPolicy.authorize(
            &request,
            trust: endpointTrust,
            bearerToken: endpointBearerToken
        ) else {
            failRequest(
                expectedID,
                generation: generation,
                message: "MCP request authentication is unavailable"
            )
            return
        }
        if method != "initialize", let negotiatedProtocolVersion {
            request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = data
        guard let expectedID else {
            // Notifications have no response authority. Sending them through a
            // normal task lets URLSession drain a short 202/empty response
            // without retaining a permanently-open SSE byte sequence.
            urlSession.dataTask(with: request).resume()
            return
        }

        // Streamable HTTP is allowed to return one JSON-RPC envelope over an
        // SSE response whose connection remains open. A completion-handler
        // data task waits for EOF and therefore leaves the UI at “Starting”
        // forever. Read bounded lines and finish as soon as the matching data
        // event arrives.
        let task = Task { [weak self, weak urlSession] in
            guard let self, let urlSession else { return }
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.finishStreamingRequest(
                        id: expectedID,
                        generation: generation,
                        method: method,
                        result: .failure("HTTP \(status)")
                    )
                    return
                }
                guard http.value(forHTTPHeaderField: "Mcp-Session-Id") == nil else {
                    self.finishStreamingRequest(
                        id: expectedID,
                        generation: generation,
                        method: method,
                        result: .stateful
                    )
                    return
                }
                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                guard contentType.hasPrefix("application/json") || contentType.hasPrefix("text/event-stream") else {
                    self.finishStreamingRequest(
                        id: expectedID,
                        generation: generation,
                        method: method,
                        result: .failure("Unexpected MCP content type")
                    )
                    return
                }

                var byteCount = 0
                var jsonBody = Data()
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    byteCount += line.utf8.count + 1
                    guard byteCount <= Self.maximumResponseBytes else {
                        self.finishStreamingRequest(
                            id: expectedID,
                            generation: generation,
                            method: method,
                            result: .oversized
                        )
                        return
                    }
                    if contentType.hasPrefix("text/event-stream") {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !payload.isEmpty, let payloadData = payload.data(using: .utf8) else { continue }
                        self.finishStreamingRequest(
                            id: expectedID,
                            generation: generation,
                            method: method,
                            result: .payload(payloadData)
                        )
                        return
                    }
                    jsonBody.append(contentsOf: line.utf8)
                    jsonBody.append(0x0A)
                }
                while jsonBody.last == 0x0A || jsonBody.last == 0x0D {
                    jsonBody.removeLast()
                }
                self.finishStreamingRequest(
                    id: expectedID,
                    generation: generation,
                    method: method,
                    result: jsonBody.isEmpty ? .failure("Empty MCP response") : .payload(jsonBody)
                )
            } catch is CancellationError {
                return
            } catch {
                self.finishStreamingRequest(
                    id: expectedID,
                    generation: generation,
                    method: method,
                    result: .failure(error.localizedDescription)
                )
            }
        }
        httpTasks[expectedID] = task
    }

    private enum StreamingRequestResult {
        case payload(Data)
        case failure(String)
        case oversized
        case stateful
    }

    private func finishStreamingRequest(
        id: Int,
        generation: UInt64,
        method: String,
        result: StreamingRequestResult
    ) {
        ioQueue.async { [weak self] in
            guard let self, generation == self.transportGeneration else { return }
            self.httpTasks.removeValue(forKey: id)
            switch result {
            case .payload(let data):
                guard self.consumeHTTP(data, expectedID: id, generation: generation) else {
                    self.failRequest(id, generation: generation, message: "Unreadable or mismatched JSON-RPC response")
                    self.handleTransportFailure(method: method, reason: "MCP endpoint returned an unreadable response")
                    return
                }
            case .failure(let reason):
                self.failRequest(id, generation: generation, message: reason)
                self.handleTransportFailure(method: method, reason: reason)
            case .oversized:
                self.failRequest(id, generation: generation, message: "MCP response exceeded the 8 MiB safety bound")
                self.scheduleReconnect(reason: "MCP response exceeded the 8 MiB safety bound")
            case .stateful:
                self.failRequest(id, generation: generation, message: "Unexpected stateful MCP session")
                self.scheduleReconnect(reason: "The exact Ouroboros 0.51.6 service must be stateless")
            }
        }
    }

    @discardableResult
    private func consumeHTTP(_ data: Data, expectedID: Int?, generation: UInt64) -> Bool {
        guard let expectedID else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let payloads: [String]
        if text.contains("data:") {
            // Swift treats CRLF as one extended grapheme, so splitting on the
            // LF character alone does not split standards-compliant SSE.
            payloads = text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = String(line)
                guard value.hasPrefix("data:") else { return nil }
                // Streamable HTTP uses SSE's CRLF line endings. Leaving the
                // trailing carriage return makes an otherwise valid JSON-RPC
                // envelope fail parsing without ever resolving its request.
                return value.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            payloads = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        var consumed = false
        for payload in payloads {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int,
                  id == expectedID,
                  let pendingRequest = pending.removeValue(forKey: id),
                  pendingRequest.generation == generation else { continue }
            consumed = true
            pendingRequest.completion(object)
        }
        return consumed || payloads.isEmpty
    }

    private func failRequest(_ id: Int?, generation: UInt64, message: String) {
        guard let id,
              let pendingRequest = pending.removeValue(forKey: id),
              pendingRequest.generation == generation else { return }
        pendingRequest.completion(["jsonrpc": "2.0", "id": id, "error": ["message": message]])
    }

    private func handleTransportFailure(method: String, reason: String) {
        if method == "initialize" {
            scheduleReconnect(reason: "MCP endpoint failed: \(reason)")
        }
    }

    private func bounded(_ value: String, limit: Int) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    private enum ClientError: LocalizedError {
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let message): message
            }
        }
    }

    private struct PendingRequest {
        let generation: UInt64
        let completion: ([String: Any]) -> Void
    }

    private enum CatalogKind {
        case tools
        case resources
        case prompts

        var method: String {
            switch self {
            case .tools: "tools/list"
            case .resources: "resources/list"
            case .prompts: "prompts/list"
            }
        }

        var resultKey: String {
            switch self {
            case .tools: "tools"
            case .resources: "resources"
            case .prompts: "prompts"
            }
        }

        var idPrefix: String {
            switch self {
            case .tools: "tool"
            case .resources: "resource"
            case .prompts: "prompt"
            }
        }

        var fallbackDetail: String {
            switch self {
            case .tools: "MCP tool"
            case .resources: "MCP resource"
            case .prompts: "MCP prompt"
            }
        }

        var collectionKind: MCPCollectionKind {
            switch self {
            case .tools: .tools
            case .resources: .resources
            case .prompts: .prompts
            }
        }
    }
}
