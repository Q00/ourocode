import Darwin
import Foundation

enum LocalMCPConnectorClass: String, Codable, Equatable {
    case external
    case managed
    case privileged
}

struct LocalMCPSourceDescriptor: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let endpointManifestPath: String
    let connectorClass: LocalMCPConnectorClass?
    let requiredMacOSPermissions: [String]?
    let approvalPolicy: String?

    init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        endpointManifestPath: String,
        connectorClass: LocalMCPConnectorClass? = nil,
        requiredMacOSPermissions: [String]? = nil,
        approvalPolicy: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.endpointManifestPath = endpointManifestPath
        self.connectorClass = connectorClass
        self.requiredMacOSPermissions = requiredMacOSPermissions
        self.approvalPolicy = approvalPolicy
    }

    var sourceID: MCPSourceID? {
        guard schemaVersion == 1,
              let id = MCPSourceID(rawValue: id),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= 80,
              endpointManifestPath.hasPrefix("/"),
              (requiredMacOSPermissions ?? []).count <= 8 else { return nil }
        return id
    }

    var effectiveConnectorClass: LocalMCPConnectorClass { connectorClass ?? .external }
}

enum LocalMCPSourceDescriptorLoader {
    static let maximumDescriptors = MCPSourceRegistry.maximumSources - 1
    static let maximumFileBytes = 64 * 1_024

    static func directory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Ourocode", isDirectory: true)
            .appendingPathComponent("mcp-sources", isDirectory: true)
    }

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [LocalMCPSourceDescriptor] {
        let root = directory(homeDirectory: homeDirectory)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var seen = Set<MCPSourceID>()
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maximumDescriptors)
            .compactMap { url in
                guard isOwnerControlledRegularFile(url.path),
                      let data = try? Data(contentsOf: url),
                      data.count <= maximumFileBytes,
                      let descriptor = try? JSONDecoder().decode(LocalMCPSourceDescriptor.self, from: data),
                      let id = descriptor.sourceID,
                      seen.insert(id).inserted else { return nil }
                return descriptor
            }
    }

    static func write(
        _ descriptor: LocalMCPSourceDescriptor,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        guard let sourceID = descriptor.sourceID else { throw LocalMCPDescriptorError.invalid }
        let root = directory(homeDirectory: homeDirectory)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.sorted.encode(descriptor)
        guard data.count <= maximumFileBytes else { throw LocalMCPDescriptorError.oversized }
        let target = root.appendingPathComponent("\(sourceID.rawValue).json")
        try data.write(to: target, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func isOwnerControlledRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && (info.st_mode & 0o022) == 0
            && info.st_uid == getuid()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum LocalMCPDescriptorError: Error {
    case invalid
    case oversized
}

final class DescriptorMCPAdapter: MCPLazyCatalogSourceAdapter {
    var onStateChange: ((OuroborosConnectionState) -> Void)?
    var onCatalogChange: ((MCPSourceCatalog) -> Void)?

    private let descriptor: LocalMCPSourceDescriptor
    private let queue: DispatchQueue
    private var inner: MCPV2CatalogAdapter?
    private var requestedCollections = Set<MCPCollectionKind>()
    private var started = false
    private var observationActive = false
    private var generation: UInt64 = 0

    init(descriptor: LocalMCPSourceDescriptor) {
        self.descriptor = descriptor
        self.queue = DispatchQueue(label: "com.ourolabs.ourocode.mcp-source.\(descriptor.id)")
    }

    func start() { resumeObservation() }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.started = false
            self.observationActive = false
            self.inner?.stop()
            self.inner = nil
        }
    }

    func retry() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.inner?.stop()
            self.inner = nil
            self.started = true
            self.observationActive = true
            self.connect()
        }
    }

    func pauseObservation() {
        queue.async { [weak self] in
            self?.observationActive = false
            self?.inner?.pauseObservation()
        }
    }

    func resumeObservation() {
        queue.async { [weak self] in
            guard let self else { return }
            self.observationActive = true
            self.started = true
            if let inner = self.inner { inner.resumeObservation() } else { self.connect() }
        }
    }

    func requestCollection(_ kind: MCPCollectionKind) {
        queue.async { [weak self] in
            self?.requestedCollections.insert(kind)
            self?.inner?.requestCollection(kind)
        }
    }

    private func connect() {
        generation &+= 1
        let activeGeneration = generation
        publish(.starting)
        guard let endpoint = DescriptorMCPEndpoint.load(path: descriptor.endpointManifestPath) else {
            publish(.offline(reason: "MCP endpoint manifest is unavailable"))
            return
        }
        let adapter = MCPV2CatalogAdapter(
            configuration: MCPV2CatalogConfiguration(
                displayName: descriptor.displayName,
                endpointDescription: "Registered local MCP · authenticated loopback"
            ),
            transport: LoopbackMCPHTTPTransport(
                endpoint: endpoint.url,
                bearerToken: endpoint.bearerToken
            )
        )
        adapter.onStateChange = { [weak self] state in self?.onStateChange?(state) }
        adapter.onCatalogChange = { [weak self] catalog in self?.onCatalogChange?(catalog) }
        guard generation == activeGeneration else { return }
        inner = adapter
        if observationActive { adapter.start() }
        requestedCollections.forEach(adapter.requestCollection)
    }

    private func publish(_ state: OuroborosConnectionState) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

private struct DescriptorMCPEndpoint {
    let url: URL
    let bearerToken: String

    static func load(path: String) -> DescriptorMCPEndpoint? {
        var info = stat()
        guard path.hasPrefix("/"), lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o022) == 0,
              info.st_uid == getuid(), info.st_size <= 64 * 1_024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let endpoint = object["endpoint"], let url = URL(string: endpoint),
              url.scheme == "http", url.host == "127.0.0.1", url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              let authorization = object["authorization"], authorization.hasPrefix("Bearer ") else {
            return nil
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return DescriptorMCPEndpoint(url: url, bearerToken: token)
    }
}
