import Foundation

struct OuroborosDashboardEndpoint: Equatable {
    let baseURL: URL
    let databasePath: String
    let processID: Int32

    func runIndexURL() -> URL { baseURL.appendingPathComponent("api/runs") }

    func eventURL(executionID: String) -> URL? {
        guard OuroborosBoardSnapshotDecoder.validIdentifier(executionID) else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "run", value: executionID)]
        return components?.url
    }

}

enum OuroborosDashboardStateDecoder {
    static let maximumBytes = 16 * 1_024
    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondTimestampFormatter = ISO8601DateFormatter()

    private static func validTimestamp(_ value: String) -> Bool {
        fractionalTimestampFormatter.date(from: value) != nil
            || wholeSecondTimestampFormatter.date(from: value) != nil
    }

    static func decode(_ data: Data) -> OuroborosDashboardEndpoint? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = boundedString(object["host"], maximum: 64),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = exactInteger(object["port"]), (1...65_535).contains(port),
              let process = exactInteger(object["pid"]), process > 0, process <= Int64(Int32.max),
              let databasePath = boundedString(object["db_path"], maximum: 4_096), databasePath.hasPrefix("/"),
              let startedAt = boundedString(object["started_at"], maximum: 128),
              validTimestamp(startedAt) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        guard let baseURL = components.url, baseURL.user == nil, baseURL.password == nil else { return nil }
        return OuroborosDashboardEndpoint(baseURL: baseURL, databasePath: databasePath, processID: Int32(process))
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return value
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }
}

enum OuroborosDashboardRunIndexDecoder {
    static let maximumBytes = 512 * 1_024
    static let maximumRuns = 256

    static func executionIDs(_ data: Data) -> [String]? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = object["runs"] as? [[String: Any]], runs.count <= maximumRuns else { return nil }
        let values = runs.compactMap { $0["execution_id"] as? String }
        guard values.count == runs.count, values.allSatisfy(OuroborosBoardSnapshotDecoder.validIdentifier),
              Set(values).count == values.count else { return nil }
        return values
    }
}

struct OuroborosBoardAgent: Equatable {
    let id: String
    let parentID: String?
    let title: String
    let status: String
    let depth: Int
    let provider: String?
    let runtimeSessionID: String?
    let tool: String?
    let model: String?
    let tokenSpend: Double?
    let acceptanceCriterionIndex: Int?
}

struct OuroborosBoardSnapshot: Equatable {
    let executionID: String
    let sessionID: String?
    let goal: String?
    let phase: String?
    let activity: String?
    let agents: [OuroborosBoardAgent]
}

enum OuroborosBoardSnapshotDecoder {
    static let maximumBytes = 1_048_576
    static let maximumAgents = 256
    private static let maximumIdentifierBytes = 512
    private static let maximumTextBytes = 8_192
    private static let columns = ["pending", "executing", "completed", "failed"]

    static func decode(_ data: Data, expectedExecutionID: String) -> OuroborosBoardSnapshot? {
        guard !data.isEmpty, data.count <= maximumBytes, validIdentifier(expectedExecutionID),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = object["meta"] as? [String: Any],
              let executionID = boundedString(meta["execution_id"], maximum: maximumIdentifierBytes),
              executionID == expectedExecutionID,
              let rawColumns = object["columns"] as? [String: Any] else { return nil }
        let sessionID = optionalString(meta["session_id"], maximum: maximumIdentifierBytes)
        let goal = optionalString(meta["goal"], maximum: maximumTextBytes)
        let phase = optionalString(meta["phase"], maximum: 256)
        let activity = optionalString(meta["activity"], maximum: 512)
        var agents: [OuroborosBoardAgent] = []
        var ids = Set<String>()
        for column in columns {
            guard let rawAgents = rawColumns[column] as? [[String: Any]],
                  agents.count + rawAgents.count <= maximumAgents else { return nil }
            for raw in rawAgents {
                guard let id = boundedString(raw["id"], maximum: maximumIdentifierBytes), ids.insert(id).inserted,
                      let status = boundedString(raw["status"], maximum: 32), status == column,
                      let depthValue = exactInteger(raw["depth"]), (0...64).contains(depthValue) else { return nil }
                agents.append(OuroborosBoardAgent(
                    id: id,
                    parentID: optionalString(raw["parent_id"], maximum: maximumIdentifierBytes),
                    title: optionalString(raw["title"], maximum: maximumTextBytes) ?? id,
                    status: status,
                    depth: Int(depthValue),
                    provider: optionalString(raw["provider"], maximum: 128),
                    runtimeSessionID: optionalString(raw["session_id"], maximum: maximumIdentifierBytes),
                    tool: optionalString(raw["tool"], maximum: 512),
                    model: optionalString(raw["model"], maximum: 512),
                    tokenSpend: finiteNumber(raw["tokens"]),
                    acceptanceCriterionIndex: optionalPositiveInteger(raw["ac_index"])
                ))
            }
        }
        guard graphIsValid(agents) else { return nil }
        return OuroborosBoardSnapshot(executionID: executionID, sessionID: sessionID, goal: goal,
                                      phase: phase, activity: activity, agents: agents)
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifierBytes
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 })
    }

    private static func graphIsValid(_ agents: [OuroborosBoardAgent]) -> Bool {
        let knownIDs = Set(agents.map(\.id))
        guard agents.allSatisfy({ $0.parentID.map(knownIDs.contains) ?? true }) else { return false }
        let parents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.parentID) })
        for agent in agents {
            var seen = Set<String>()
            var cursor: String? = agent.id
            while let id = cursor {
                guard seen.insert(id).inserted else { return false }
                cursor = parents[id] ?? nil
            }
        }
        return true
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else { return nil }
        return value
    }

    private static func optionalString(_ value: Any?, maximum: Int) -> String? {
        if value == nil || value is NSNull { return nil }
        return boundedString(value, maximum: maximum)
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func optionalPositiveInteger(_ value: Any?) -> Int? {
        if value == nil || value is NSNull { return nil }
        guard let result = exactInteger(value), result > 0, result <= Int64(Int.max) else { return nil }
        return Int(result)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        if value == nil || value is NSNull { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }
}

private final class OuroborosAgentEventHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class OuroborosAgentEventFeed: @unchecked Sendable {
    static let maximumConcurrentFeeds = 8
    static let refreshSeconds: TimeInterval = 5
    var onSnapshot: ((OuroborosBoardSnapshot) -> Void)?

    private struct Feed {
        let generation: UInt64
        let endpoint: OuroborosDashboardEndpoint
        let task: Task<Void, Never>
    }

    private let callbackQueue: DispatchQueue
    private let stateFileURL: URL
    private var requestedExecutionIDs: [String] = []
    private var desiredExecutionIDs: [String] = []
    private var followsRunIndex = true
    private var feeds: [String: Feed] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var refreshTimer: DispatchSourceTimer?
    private var nextGeneration: UInt64 = 0
    private var session: URLSession?
    private var sessionDelegate: OuroborosAgentEventHTTPDelegate?

    init(callbackQueue: DispatchQueue,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.callbackQueue = callbackQueue
        stateFileURL = homeDirectory.appendingPathComponent(".ouroboros", isDirectory: true)
            .appendingPathComponent("dashboard.json")
    }

    func synchronize(executionIDs: [String]) {
        var seen = Set<String>()
        requestedExecutionIDs = executionIDs.filter {
            OuroborosBoardSnapshotDecoder.validIdentifier($0) && seen.insert($0).inserted
        }.prefix(Self.maximumConcurrentFeeds).map { $0 }
        followsRunIndex = requestedExecutionIDs.isEmpty
        if refreshTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
            timer.schedule(deadline: .now(), repeating: Self.refreshSeconds)
            timer.setEventHandler { [weak self] in self?.refreshIndex() }
            timer.resume()
            refreshTimer = timer
        }
        refreshIndex()
    }

    func stop() {
        requestedExecutionIDs.removeAll(keepingCapacity: true)
        desiredExecutionIDs.removeAll(keepingCapacity: true)
        followsRunIndex = true
        refreshTimer?.cancel()
        refreshTimer = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        cancelFeeds()
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
    }

    private func refreshIndex() {
        guard let endpoint = readEndpoint() else { cancelFeeds(); return }
        discoverRuns(endpoint: endpoint)
    }

    private func readEndpoint() -> OuroborosDashboardEndpoint? {
        guard let data = try? Data(contentsOf: stateFileURL, options: [.mappedIfSafe]) else { return nil }
        return OuroborosDashboardStateDecoder.decode(data)
    }

    private func makeSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let delegate = OuroborosAgentEventHTTPDelegate()
        sessionDelegate = delegate
        let created = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session = created
        return created
    }

    private func discoverRuns(endpoint: OuroborosDashboardEndpoint) {
        discoveryTask?.cancel()
        let requested = requestedExecutionIDs
        let followMode = followsRunIndex
        let session = makeSession()
        var request = URLRequest(url: endpoint.runIndexURL())
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        discoveryTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("application/json"),
                      let available = OuroborosDashboardRunIndexDecoder.executionIDs(data) else { return }
                self.callbackQueue.async { [weak self] in
                    guard let self, self.followsRunIndex == followMode,
                          followMode || self.requestedExecutionIDs == requested else { return }
                    let availableSet = Set(available)
                    let selected = followMode ? Array(available.prefix(Self.maximumConcurrentFeeds))
                        : requested.filter(availableSet.contains)
                    self.desiredExecutionIDs = selected
                    self.reconcileFeeds(executionIDs: selected, endpoint: endpoint)
                }
            } catch { return }
        }
    }

    private func reconcileFeeds(executionIDs: [String], endpoint: OuroborosDashboardEndpoint) {
        let permitted = Set(executionIDs)
        for executionID in Array(feeds.keys) where !permitted.contains(executionID) {
            feeds.removeValue(forKey: executionID)?.task.cancel()
        }
        for executionID in executionIDs {
            if let existing = feeds[executionID], existing.endpoint == endpoint { continue }
            feeds.removeValue(forKey: executionID)?.task.cancel()
            startFeed(executionID: executionID, endpoint: endpoint)
        }
    }

    private func startFeed(executionID: String, endpoint: OuroborosDashboardEndpoint) {
        guard let eventURL = endpoint.eventURL(executionID: executionID) else { return }
        nextGeneration &+= 1
        let generation = nextGeneration
        let session = makeSession()
        var request = URLRequest(url: eventURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                self.callbackQueue.async { [weak self] in
                    guard let self, self.feeds[executionID]?.generation == generation else { return }
                    self.feeds.removeValue(forKey: executionID)
                }
            }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/event-stream") else { return }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard payload.utf8.count <= OuroborosBoardSnapshotDecoder.maximumBytes,
                          let data = payload.data(using: .utf8),
                          let snapshot = OuroborosBoardSnapshotDecoder.decode(data, expectedExecutionID: executionID) else { continue }
                    self.callbackQueue.async { [weak self] in
                        guard let self, self.desiredExecutionIDs.contains(executionID),
                              self.feeds[executionID]?.generation == generation else { return }
                        self.onSnapshot?(snapshot)
                    }
                }
            } catch { return }
        }
        feeds[executionID] = Feed(generation: generation, endpoint: endpoint, task: task)
    }

    private func cancelFeeds() {
        feeds.values.forEach { $0.task.cancel() }
        feeds.removeAll(keepingCapacity: true)
    }
}
