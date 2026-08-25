import Foundation
import OSLog

struct SharedCUAEndpoint: Equatable {
    let endpoint: URL
    let bearerToken: String
}

enum SharedCUAServiceRuntime {
    static let endpoint = URL(string: "http://127.0.0.1:9877/mcp")!
    static let launchdLabel = "com.ourolabs.ourocode.cua-mcp"
    static let tokenEnvironmentKey = "CUA_HTTP_TOKEN"
    private static let logger = Logger(subsystem: "com.ourolabs.ourocode", category: "shared-cua")
    private static let queue = DispatchQueue(label: "com.ourolabs.ourocode.shared-cua", qos: .utility)
    private static let lock = NSLock()
    private static var running = false
    private static var waiters: [(Result<SharedCUAEndpoint, Error>) -> Void] = []

    static func start(completion: @escaping (Result<SharedCUAEndpoint, Error>) -> Void) {
        lock.lock()
        waiters.append(completion)
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { startSynchronously() }
    }

    static func endpointFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Ourocode", isDirectory: true)
            .appendingPathComponent("cua-mcp-endpoint.json")
    }

    static func currentToken(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let url = homeDirectory
            .appendingPathComponent("Library/Application Support/Ourocode", isDirectory: true)
            .appendingPathComponent("cua-mcp.token")
        guard let token = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedCUABearerToken.isValid(value) ? value : nil
    }

    static func descriptor(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LocalMCPSourceDescriptor {
        LocalMCPSourceDescriptor(
            schemaVersion: 1,
            id: "computer-use",
            displayName: "Computer Use",
            endpointManifestPath: endpointFileURL(homeDirectory: homeDirectory).path,
            connectorClass: .privileged,
            requiredMacOSPermissions: ["accessibility", "screen-recording"],
            approvalPolicy: "session-and-action"
        )
    }

    private static func startSynchronously() {
        let result: Result<SharedCUAEndpoint, Error>
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appendingPathComponent(
                "Library/Application Support/Ourocode", isDirectory: true
            )
            let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard let cua = CUAInstallationLocator.firstExecutable(named: "cua-rs") else {
                throw SharedCUAError.executableMissing
            }
            let tokenURL = support.appendingPathComponent("cua-mcp.token")
            let token: String
            if let existing = try? String(contentsOf: tokenURL, encoding: .utf8),
               SharedCUABearerToken.isValid(existing.trimmingCharacters(in: .whitespacesAndNewlines)) {
                token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                token = SharedCUABearerToken.generate()
                try Data(token.utf8).write(to: tokenURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            }
            let plistURL = launchAgents.appendingPathComponent("\(launchdLabel).plist")
            let plist = try makePlist(cuaPath: cua.path, token: token, home: home.path)
            try plist.write(to: plistURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            _ = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"])
            guard waitUntilReady(token: token, timeout: 10) else {
                throw SharedCUAError.readinessTimedOut
            }
            let endpointRecord: [String: String] = [
                "endpoint": endpoint.absoluteString,
                "authorization": "Bearer \(token)",
                "launchdLabel": launchdLabel,
                "serverVersion": CUAInstallationLocator.pinnedVersion,
            ]
            let endpointData = try JSONSerialization.data(withJSONObject: endpointRecord, options: [.sortedKeys])
            let endpointURL = endpointFileURL(homeDirectory: home)
            try endpointData.write(to: endpointURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)
            try LocalMCPSourceDescriptorLoader.write(
                descriptor(homeDirectory: home),
                homeDirectory: home
            )
            result = .success(SharedCUAEndpoint(endpoint: endpoint, bearerToken: token))
        } catch {
            logger.error("startup_failed: \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        }
        lock.lock()
        let callbacks = waiters
        waiters.removeAll(keepingCapacity: false)
        running = false
        lock.unlock()
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }

    private static func makePlist(cuaPath: String, token: String, home: String) throws -> Data {
        let values: [String: Any] = [
            "Label": launchdLabel,
            "ProgramArguments": [cuaPath, "127.0.0.1:9877"],
            "EnvironmentVariables": [
                "HOME": home,
                tokenEnvironmentKey: token,
                "CUA_YIELD_TO_HUMAN": "1",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func waitUntilReady(token: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe(token: token) { return true }
            usleep(100_000)
        }
        return false
    }

    private static func probe(token: String) -> Bool {
        var request = URLRequest(url: endpoint, timeoutInterval: 0.5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                       "clientInfo": ["name": "ourocode-readiness", "version": "1"]]
        ])
        let semaphore = DispatchSemaphore(value: 0)
        var ready = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let text = String(data: data, encoding: .utf8) else { return }
            ready = text.contains("serverInfo") && text.contains("cua")
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.6)
        return ready
    }
}

enum SharedCUABearerToken {
    static let length = 64

    static func generate() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum SharedCUAError: LocalizedError {
    case executableMissing
    case readinessTimedOut

    var errorDescription: String? {
        switch self {
        case .executableMissing: return "cua-rs is not installed"
        case .readinessTimedOut: return "Computer Use service did not become ready"
        }
    }
}
