import Darwin
import Foundation
import OSLog

enum OuroborosEndpointTrust: String, Codable, Equatable {
    case localUnauthenticated
    case managedAuthenticated
    case explicitUserConfigured
}

/// Loopback catalog trust is sufficient for bounded, read-only target/surface
/// correlation. It is never sufficient to copy delivery capabilities into UI
/// steering authority; that remains broker-authenticated on a separate path.
enum OuroborosTargetOverlayTrustPolicy {
    static func permitsReadOnlyDiscovery(_ trust: OuroborosEndpointTrust?) -> Bool {
        trust != nil
    }

    static func permitsAdvertisedDeliveryModes(_ trust: OuroborosEndpointTrust?) -> Bool {
        trust == .managedAuthenticated
    }
}

/// One app-owned credential for the retained loopback service. The token is
/// deliberately absent from command-line arguments and the Codable launch
/// contract; the owner-only launchd plist is the sole durable copy.
struct OuroborosManagedEndpoint: Equatable {
    let endpoint: URL
    let bearerToken: String

    init?(endpoint: URL, bearerToken: String) {
        guard endpoint == SharedOuroborosResolver.defaultEndpoint,
              SharedOuroborosBearerToken.isValid(bearerToken) else { return nil }
        self.endpoint = endpoint
        self.bearerToken = bearerToken
    }
}

enum SharedOuroborosBearerToken {
    static let environmentKey = "OUROBOROS_MCP_AUTH_TOKEN"
    static let hexadecimalLength = 64

    static func generate() -> String {
        (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == hexadecimalLength && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum SharedOuroborosBridgeConfig {
    static let fileName = "ouroboros-mcp-bridge-cua-v1.yaml"
    static let data = Data([
        "mcp_servers:",
        "  - name: cua-rs",
        "    transport: stdio",
        "    command: /usr/bin/env",
        "    args:",
        "      - ourocode-cua-mcp-bridge",
        "      - cua-rs",
        "    env:",
        "      PATH: \"${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"",
        "      CUA_YIELD_TO_HUMAN: \"1\"",
        "      PYTHONDONTWRITEBYTECODE: \"1\"",
        "connection:",
        "  timeout_seconds: 30",
        "  retry_attempts: 2",
        "  health_check_interval: 60",
        "tool_prefix: \"cua_\"",
        "",
    ].joined(separator: "\n").utf8)

    static func matches(_ candidate: Data) -> Bool { candidate == data }
}

enum OuroborosRequestAuthorizationPolicy {
    /// Apply the managed credential only to the exact retained endpoint.
    /// Returning false means the caller must not send the request.
    static func authorize(
        _ request: inout URLRequest,
        trust: OuroborosEndpointTrust?,
        bearerToken: String?
    ) -> Bool {
        switch trust {
        case .managedAuthenticated:
            guard request.url == SharedOuroborosResolver.defaultEndpoint,
                  let bearerToken,
                  SharedOuroborosBearerToken.isValid(bearerToken) else { return false }
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            return true
        case .localUnauthenticated, .explicitUserConfigured:
            return bearerToken == nil
        case nil:
            return false
        }
    }
}

struct OuroborosServiceVersion: Codable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }
}

enum BoundedProbeResult<Value: Equatable>: Equatable {
    case value(Value)
    case timeout
    case malformed
    case failed(exitCode: Int32)
}

enum OuroborosMCPCapability: String, Equatable {
    case mcpV2Supported
    case officialDistributionMissingMCPExtras
    case unsupported
}

struct OuroborosExecutableProbe: Equatable {
    let executablePath: String
    let isExecutable: Bool
    let version: BoundedProbeResult<OuroborosServiceVersion>
    let mcpCapability: BoundedProbeResult<OuroborosMCPCapability>
}

struct AuxiliaryExecutableProbe: Equatable {
    let executablePath: String
    let isExecutable: Bool
    let mcpCapability: BoundedProbeResult<OuroborosMCPCapability>
}

enum OuroborosSharedInvocation: String, Codable, Equatable {
    case installedOuroboros
    case isolatedUVX
    case managedToolRuntime
}

struct OuroborosSharedLaunchContract: Codable, Equatable {
    let schemaVersion: Int
    let launchdLabel: String
    let serviceVersion: OuroborosServiceVersion
    let endpoint: URL
    let endpointTrust: OuroborosEndpointTrust
    let invocation: OuroborosSharedInvocation
    let executablePath: String
    let arguments: [String]
    let bridgeConfigPath: String
    let workingDirectory: String

    var programArguments: [String] { [executablePath] + arguments }
}

enum SharedOuroborosResolutionFailure: Error, Equatable {
    case unavailable
    case invalidOverride
    case executableNotAbsolute
    case executableUnavailable
    case versionProbeTimedOut
    case versionProbeMalformed
    case versionProbeFailed(exitCode: Int32)
    case wrongVersion(found: OuroborosServiceVersion)
    case doctorTimedOut
    case doctorMalformed
    case doctorFailed(exitCode: Int32)
    case mcpV2Unsupported
    case uvxUnavailable
    case uvxProbeTimedOut
    case uvxProbeMalformed
    case uvxProbeFailed(exitCode: Int32)
    case uvxMCPV2Unsupported
    case bridgeConfigInvalid
}

/// Protocol revisions that the pinned Ouroboros 0.51.6 HTTP transport can
/// negotiate safely. FastMCP currently selects 2025-03-26 even when the
/// client offers 2025-06-18, so the selected revision must be carried forward
/// instead of treating a valid downgrade as an offline endpoint.
enum OuroborosMCPProtocolVersion {
    static let preferred = "2025-06-18"
    static let compatible = "2025-03-26"
    static let supported: Set<String> = [preferred, compatible]

    static func accepts(_ value: String?) -> Bool {
        guard let value else { return false }
        return supported.contains(value)
    }
}

/// Pure policy resolver. Discovery and subprocess probing happen outside this
/// type, so tests can prove every decision without touching the user's system.
enum SharedOuroborosResolver {
    static let requiredVersion = OuroborosServiceVersion(major: 0, minor: 51, patch: 6)
    static let defaultEndpoint = URL(string: "http://127.0.0.1:8976/mcp")!

    /// The retained Ouroboros identity remains stable; only its bridge config
    /// changes from an owned stdio child to the shared CUA MCP endpoint.
    static let sharedLaunchdLabel = "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.runtime-v5-cua-v0-9-1"
    static let legacyRuntimeV4LaunchdLabel = "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.runtime-v4"
    static let legacyAuthenticatedLaunchdLabel = "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.auth-v3"
    static let legacyUnauthenticatedLaunchdLabel = "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-6.cwd-v2"
    static let knownLegacyServices: [(label: String, version: OuroborosServiceVersion)] = [
        (
            "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-1.cwd-v2",
            OuroborosServiceVersion(major: 0, minor: 51, patch: 1)
        ),
        (
            "com.ourolabs.ourocode.ouroboros-mcp.dev.v0-51-5.cwd-v2",
            OuroborosServiceVersion(major: 0, minor: 51, patch: 5)
        ),
        (legacyUnauthenticatedLaunchdLabel, requiredVersion),
    ]

    static let directArguments = [
        "mcp", "serve",
        "--runtime", "codex",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", "8976",
    ]

    static let isolatedUVXPrefixArguments = [
        "--offline",
        "--no-python-downloads",
        "--no-config",
        "--no-env-file",
        "--python", ">=3.12",
        "--isolated",
        "--from", "ouroboros-ai[mcp]==0.51.6",
    ]

    static let isolatedUVXArguments = isolatedUVXPrefixArguments + [
        "ouroboros", "mcp", "serve",
        "--runtime", "codex",
        "--transport", "streamable-http",
        "--host", "127.0.0.1",
        "--port", "8976",
    ]

    struct Input: Equatable {
        /// If present, discovery must have probed this exact absolute path.
        /// A bad override is never ignored in favor of another executable.
        let executableOverride: String?
        let installedOuroboros: OuroborosExecutableProbe?
        let uvx: AuxiliaryExecutableProbe?
        let bridgeConfigPath: String
        let workingDirectory: String

        init(
            executableOverride: String? = nil,
            installedOuroboros: OuroborosExecutableProbe?,
            uvx: AuxiliaryExecutableProbe? = nil,
            bridgeConfigPath: String = "/Applications/Ourocode.app/Contents/Resources/ouroboros-mcp-bridge-cua.yaml",
            workingDirectory: String = "/Users/ourocode"
        ) {
            self.executableOverride = executableOverride
            self.installedOuroboros = installedOuroboros
            self.uvx = uvx
            self.bridgeConfigPath = bridgeConfigPath
            self.workingDirectory = workingDirectory
        }
    }

    static func resolve(_ input: Input) -> Result<OuroborosSharedLaunchContract, SharedOuroborosResolutionFailure> {
        if let override = input.executableOverride {
            guard isCanonicalAbsolutePath(override),
                  input.installedOuroboros?.executablePath == override else {
                return .failure(.invalidOverride)
            }
        }

        guard let installed = input.installedOuroboros else {
            return isolatedUVXContract(input, installedFailure: .unavailable)
        }
        guard isCanonicalAbsolutePath(installed.executablePath) else {
            return .failure(.executableNotAbsolute)
        }
        guard installed.isExecutable else {
            return isolatedUVXContract(input, installedFailure: .executableUnavailable)
        }
        guard isCanonicalAbsolutePath(input.bridgeConfigPath) else {
            return .failure(.bridgeConfigInvalid)
        }
        guard isCanonicalAbsolutePath(input.workingDirectory), input.workingDirectory != "/" else {
            return .failure(.bridgeConfigInvalid)
        }

        switch installed.version {
        case .value(let version):
            guard version == requiredVersion else {
                guard input.executableOverride == nil else {
                    return .failure(.wrongVersion(found: version))
                }
                return isolatedUVXContract(input, installedFailure: .wrongVersion(found: version))
            }
        case .timeout:
            return .failure(.versionProbeTimedOut)
        case .malformed:
            return .failure(.versionProbeMalformed)
        case .failed(let exitCode):
            return .failure(.versionProbeFailed(exitCode: exitCode))
        }

        switch installed.mcpCapability {
        case .value(.mcpV2Supported):
            return .success(contract(
                invocation: .installedOuroboros,
                executablePath: installed.executablePath,
                arguments: directArguments,
                bridgeConfigPath: input.bridgeConfigPath,
                workingDirectory: input.workingDirectory
            ))
        case .value(.officialDistributionMissingMCPExtras):
            guard let uvx = input.uvx,
                  uvx.isExecutable,
                  isCanonicalAbsolutePath(uvx.executablePath) else {
                return .failure(.uvxUnavailable)
            }
            switch uvx.mcpCapability {
            case .value(.mcpV2Supported): break
            case .value: return .failure(.uvxMCPV2Unsupported)
            case .timeout: return .failure(.uvxProbeTimedOut)
            case .malformed: return .failure(.uvxProbeMalformed)
            case .failed(let exitCode): return .failure(.uvxProbeFailed(exitCode: exitCode))
            }
            return .success(contract(
                invocation: .isolatedUVX,
                executablePath: uvx.executablePath,
                arguments: isolatedUVXArguments,
                bridgeConfigPath: input.bridgeConfigPath,
                workingDirectory: input.workingDirectory
            ))
        case .value(.unsupported):
            return .failure(.mcpV2Unsupported)
        case .timeout:
            return .failure(.doctorTimedOut)
        case .malformed:
            return .failure(.doctorMalformed)
        case .failed(let exitCode):
            return .failure(.doctorFailed(exitCode: exitCode))
        }
    }

    private static func isolatedUVXContract(
        _ input: Input,
        installedFailure: SharedOuroborosResolutionFailure
    ) -> Result<OuroborosSharedLaunchContract, SharedOuroborosResolutionFailure> {
        guard let uvx = input.uvx,
              uvx.isExecutable,
              isCanonicalAbsolutePath(uvx.executablePath) else {
            return .failure(installedFailure)
        }
        switch uvx.mcpCapability {
        case .value(.mcpV2Supported):
            return .success(contract(
                invocation: .isolatedUVX,
                executablePath: uvx.executablePath,
                arguments: isolatedUVXArguments,
                bridgeConfigPath: input.bridgeConfigPath,
                workingDirectory: input.workingDirectory
            ))
        case .value: return .failure(.uvxMCPV2Unsupported)
        case .timeout: return .failure(.uvxProbeTimedOut)
        case .malformed: return .failure(.uvxProbeMalformed)
        case .failed(let exitCode): return .failure(.uvxProbeFailed(exitCode: exitCode))
        }
    }

    static func validate(_ contract: OuroborosSharedLaunchContract) -> Bool {
        guard contract.schemaVersion == 5,
              contract.launchdLabel == sharedLaunchdLabel,
              contract.serviceVersion == requiredVersion,
              contract.endpoint == defaultEndpoint,
              contract.endpointTrust == .managedAuthenticated,
              isCanonicalAbsolutePath(contract.executablePath),
              isCanonicalAbsolutePath(contract.bridgeConfigPath),
              isCanonicalAbsolutePath(contract.workingDirectory),
              contract.workingDirectory != "/",
              !contract.arguments.contains("--auth-token"),
              !contract.arguments.contains(where: { $0.contains(SharedOuroborosBearerToken.environmentKey) }) else {
            return false
        }
        switch contract.invocation {
        case .installedOuroboros:
            return contract.arguments == directArguments
        case .isolatedUVX:
            // This is a probe result, never a durable launchd contract. uvx's
            // archive environment may be unlinked while a retained process is
            // still alive, making later lazy imports fail.
            return false
        case .managedToolRuntime:
            return contract.arguments == directArguments
        }
    }

    static func pinManagedRuntime(
        _ probedContract: OuroborosSharedLaunchContract,
        executablePath: String
    ) -> Result<OuroborosSharedLaunchContract, SharedOuroborosResolutionFailure> {
        guard probedContract.schemaVersion == 5,
              probedContract.launchdLabel == sharedLaunchdLabel,
              probedContract.serviceVersion == requiredVersion,
              probedContract.endpoint == defaultEndpoint,
              probedContract.endpointTrust == .managedAuthenticated,
              probedContract.invocation == .isolatedUVX,
              probedContract.arguments == isolatedUVXArguments,
              isCanonicalAbsolutePath(executablePath) else {
            return .failure(.invalidOverride)
        }
        return .success(contract(
            invocation: .managedToolRuntime,
            executablePath: executablePath,
            arguments: directArguments,
            bridgeConfigPath: probedContract.bridgeConfigPath,
            workingDirectory: probedContract.workingDirectory
        ))
    }

    private static func contract(
        invocation: OuroborosSharedInvocation,
        executablePath: String,
        arguments: [String],
        bridgeConfigPath: String,
        workingDirectory: String
    ) -> OuroborosSharedLaunchContract {
        OuroborosSharedLaunchContract(
            schemaVersion: 5,
            launchdLabel: sharedLaunchdLabel,
            serviceVersion: requiredVersion,
            endpoint: defaultEndpoint,
            endpointTrust: .managedAuthenticated,
            invocation: invocation,
            executablePath: executablePath,
            arguments: arguments,
            bridgeConfigPath: bridgeConfigPath,
            workingDirectory: workingDirectory
        )
    }

    fileprivate static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty, !path.contains("\0") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}

/// Bounded inspection of the exact binaries selected by LaunchConfiguration.
/// `mcp serve --help` is deliberately not treated as a capability check:
/// Ouroboros 0.51.6 exposes that help even when its installed Python profile
/// cannot import the MCP 2 runtime.
enum SharedOuroborosRuntimeProbe {
    private static let maximumCapturedBytes = 64 * 1_024

    static func inspect(
        ouroborosPath: String,
        uvxPath: String?,
        bridgeConfigPath: String
    ) -> (OuroborosExecutableProbe, AuxiliaryExecutableProbe?) {
        let installedExecutable = FileManager.default.isExecutableFile(atPath: ouroborosPath)
        let version: BoundedProbeResult<OuroborosServiceVersion>
        let capability: BoundedProbeResult<OuroborosMCPCapability>
        if installedExecutable {
            version = probeVersion(executablePath: ouroborosPath)
            capability = probeMCP(
                executablePath: ouroborosPath,
                arguments: ["mcp", "doctor"],
                bridgeConfigPath: bridgeConfigPath,
                officialInstalledProfile: true
            )
        } else {
            version = .failed(exitCode: ENOENT)
            capability = .failed(exitCode: ENOENT)
        }

        let installed = OuroborosExecutableProbe(
            executablePath: ouroborosPath,
            isExecutable: installedExecutable,
            version: version,
            mcpCapability: capability
        )
        guard let uvxPath else { return (installed, nil) }
        let uvxExecutable = FileManager.default.isExecutableFile(atPath: uvxPath)
        let uvxCapability: BoundedProbeResult<OuroborosMCPCapability>
        if uvxExecutable {
            uvxCapability = probeMCP(
                executablePath: uvxPath,
                arguments: SharedOuroborosResolver.isolatedUVXPrefixArguments +
                    ["ouroboros", "mcp", "doctor"],
                bridgeConfigPath: bridgeConfigPath,
                officialInstalledProfile: false
            )
        } else {
            uvxCapability = .failed(exitCode: ENOENT)
        }
        return (
            installed,
            AuxiliaryExecutableProbe(
                executablePath: uvxPath,
                isExecutable: uvxExecutable,
                mcpCapability: uvxCapability
            )
        )
    }

    static func parseVersion(_ output: String, exitCode: Int32) -> BoundedProbeResult<OuroborosServiceVersion> {
        guard exitCode == 0 else { return .failed(exitCode: exitCode) }
        // GUI launch environments can make Rich emit terminal decoration or a
        // short launcher notice even though stdout is a pipe. Trust only the
        // exact version phrase, but do not require it to be the only bytes in
        // the bounded probe output.
        let pattern = #"Ouroboros\s+version\s+([0-9]+)\.([0-9]+)\.([0-9]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: output),
              let minorRange = Range(match.range(at: 2), in: output),
              let patchRange = Range(match.range(at: 3), in: output),
              let major = Int(output[majorRange]),
              let minor = Int(output[minorRange]),
              let patch = Int(output[patchRange]) else { return .malformed }
        return .value(.init(major: major, minor: minor, patch: patch))
    }

    static func parseMCPCapability(
        _ output: String,
        exitCode: Int32,
        officialInstalledProfile: Bool
    ) -> BoundedProbeResult<OuroborosMCPCapability> {
        if let data = output.data(using: .utf8),
           let checks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let version = checks.first { $0["name"] as? String == "ouroboros_version" }
            let mcp = checks.first { $0["name"] as? String == "mcp_import" }
            let exactVersion = version?["status"] as? String == "pass" &&
                version?["message"] as? String == "ouroboros-ai 0.51.6"
            let mcpStatus = mcp?["status"] as? String
            let mcpMessage = (mcp?["message"] as? String)?.lowercased() ?? ""
            if exactVersion, mcpStatus == "pass", mcpMessage.hasPrefix("mcp 2.") {
                return .value(.mcpV2Supported)
            }
            if officialInstalledProfile,
               exactVersion,
               mcpStatus == "fail",
               (mcpMessage.contains("is not the required mcp 2 runtime") ||
                mcpMessage.contains("mcp dependencies not installed")) {
                return .value(.officialDistributionMissingMCPExtras)
            }
            if exitCode != 0 { return .failed(exitCode: exitCode) }
            return checks.isEmpty ? .malformed : .value(.unsupported)
        }
        let normalized = output.lowercased()
        let exactVersion = normalized.contains("ouroboros_version: ouroboros-ai 0.51.6")
        if exactVersion,
           normalized.contains("mcp_import: mcp 2.") {
            // Doctor can still exit 1 for an unrelated configured runtime or
            // optional backend. The MCP import line is the narrow capability
            // this launch contract needs and is authoritative in 0.51.6.
            return .value(.mcpV2Supported)
        }
        if officialInstalledProfile,
           exactVersion,
           (normalized.contains("is not the required mcp 2 runtime") ||
            normalized.contains("mcp dependencies not installed")) {
            return .value(.officialDistributionMissingMCPExtras)
        }
        if exitCode != 0 { return .failed(exitCode: exitCode) }
        return output.isEmpty ? .malformed : .value(.unsupported)
    }

    private static func probeVersion(executablePath: String) -> BoundedProbeResult<OuroborosServiceVersion> {
        switch run(
            executablePath: executablePath,
            arguments: ["--version"],
            timeout: 4,
            environment: ["NO_COLOR": "1", "TERM": "dumb"]
        ) {
        case .completed(let exitCode, let output): return parseVersion(output, exitCode: exitCode)
        case .timeout: return .timeout
        case .launchFailed(let exitCode): return .failed(exitCode: exitCode)
        }
    }

    private static func probeMCP(
        executablePath: String,
        arguments: [String],
        bridgeConfigPath: String,
        officialInstalledProfile: Bool
    ) -> BoundedProbeResult<OuroborosMCPCapability> {
        switch run(
            executablePath: executablePath,
            arguments: arguments + ["--json"],
            timeout: 8,
            environment: ["OUROBOROS_MCP_CONFIG": bridgeConfigPath, "NO_COLOR": "1"]
        ) {
        case .completed(let exitCode, let output):
            return parseMCPCapability(
                output,
                exitCode: exitCode,
                officialInstalledProfile: officialInstalledProfile
            )
        case .timeout: return .timeout
        case .launchFailed(let exitCode): return .failed(exitCode: exitCode)
        }
    }

    enum CommandResult {
        case completed(exitCode: Int32, output: String)
        case timeout
        case launchFailed(exitCode: Int32)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, SharedOuroborosRuntimeProbe.maximumCapturedBytes - data.count)
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        environment additions: [String: String] = [:]
    ) -> CommandResult {
        guard timeout > 0, timeout <= 30,
              SharedOuroborosResolver.isCanonicalAbsolutePath(executablePath) else {
            return .launchFailed(exitCode: EINVAL)
        }
        let process = Process()
        let pipe = Pipe()
        let buffer = OutputBuffer()
        let reachedEOF = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                reachedEOF.signal()
            } else {
                buffer.append(chunk)
            }
        }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .launchFailed(exitCode: Int32((error as NSError).code))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = reachedEOF.wait(timeout: .now() + 0.5)
            pipe.fileHandleForReading.readabilityHandler = nil
            return .timeout
        }
        process.waitUntilExit()
        _ = reachedEOF.wait(timeout: .now() + 0.5)
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { buffer.append(tail) }
        return .completed(exitCode: process.terminationStatus, output: buffer.string)
    }
}

enum ManagedOuroborosRuntimeFailure: Error, Equatable {
    case invalidPaths
    case uvUnavailable
    case installTimedOut
    case installFailed(exitCode: Int32)
    case existingRuntimeInvalid
    case validationFailed
    case ioFailure
}

/// Turns a successful, pinned uvx capability probe into a relocatable,
/// app-owned tool environment. uv is allowed to read its download cache only
/// while preparing the environment; launchd never executes uv/uvx and every
/// installed package is copied out of the cache so later cache cleanup cannot
/// remove modules that Ouroboros imports lazily.
enum ManagedOuroborosRuntimeMaterializer {
    typealias CommandRunner = (
        _ executablePath: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) -> SharedOuroborosRuntimeProbe.CommandResult

    static let directoryName = "ouroboros-ai-0.51.6-mcp-v1"
    static let packageRequirement = "ouroboros-ai[mcp]==0.51.6"

    static let venvArgumentPrefix = [
        "venv", "--offline", "--no-config", "--no-python-downloads",
        "--python", ">=3.12", "--relocatable",
    ]
    static let installArgumentPrefix = [
        "pip", "install", "--offline", "--no-config", "--no-python-downloads",
        "--no-sources", "--link-mode", "copy", "--python",
    ]

    static func runtimeDirectory(contractDirectory: String) -> String {
        (contractDirectory as NSString)
            .appendingPathComponent("Runtimes/\(directoryName)")
    }

    static func uvExecutablePath(forUVXPath uvxPath: String) -> String? {
        guard SharedOuroborosResolver.isCanonicalAbsolutePath(uvxPath),
              (uvxPath as NSString).lastPathComponent == "uvx" else { return nil }
        let candidate = ((uvxPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("uv")
        guard SharedOuroborosResolver.isCanonicalAbsolutePath(candidate),
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return candidate
    }

    static func prepare(
        uvxPath: String,
        contractDirectory: String,
        bridgeConfigPath: String,
        homeDirectory: String,
        commandRunner: CommandRunner = SharedOuroborosRuntimeProbe.run
    ) -> Result<String, ManagedOuroborosRuntimeFailure> {
        guard SharedOuroborosResolver.isCanonicalAbsolutePath(contractDirectory),
              SharedOuroborosResolver.isCanonicalAbsolutePath(bridgeConfigPath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(homeDirectory) else {
            return .failure(.invalidPaths)
        }
        guard let uvPath = uvExecutablePath(forUVXPath: uvxPath) else {
            return .failure(.uvUnavailable)
        }
        let parent = (contractDirectory as NSString).appendingPathComponent("Runtimes")
        let destination = runtimeDirectory(contractDirectory: contractDirectory)
        do {
            try ensureOwnerOnlyDirectory(contractDirectory)
            try ensureOwnerOnlyDirectory(parent)
            if FileManager.default.fileExists(atPath: destination) {
                return validate(
                    runtimeDirectory: destination,
                    bridgeConfigPath: bridgeConfigPath,
                    homeDirectory: homeDirectory,
                    commandRunner: commandRunner
                ) ? .success(executablePath(runtimeDirectory: destination))
                  : .failure(.existingRuntimeInvalid)
            }

            let staging = (parent as NSString).appendingPathComponent(
                ".\(directoryName).\(UUID().uuidString).installing"
            )
            guard mkdir(staging, 0o700) == 0 else { return .failure(.ioFailure) }
            var ownsStaging = true
            defer {
                if ownsStaging {
                    try? FileManager.default.removeItem(atPath: staging)
                }
            }
            let environment = installEnvironment(homeDirectory: homeDirectory)
            switch commandRunner(
                uvPath,
                venvArgumentPrefix + [staging],
                30,
                environment
            ) {
            case .completed(let exitCode, _):
                guard exitCode == 0 else { return .failure(.installFailed(exitCode: exitCode)) }
            case .timeout:
                return .failure(.installTimedOut)
            case .launchFailed(let exitCode):
                return .failure(.installFailed(exitCode: exitCode))
            }
            let stagingPython = (staging as NSString).appendingPathComponent("bin/python")
            switch commandRunner(
                uvPath,
                installArgumentPrefix + [stagingPython, packageRequirement],
                30,
                environment
            ) {
            case .completed(let exitCode, _):
                guard exitCode == 0 else { return .failure(.installFailed(exitCode: exitCode)) }
            case .timeout:
                return .failure(.installTimedOut)
            case .launchFailed(let exitCode):
                return .failure(.installFailed(exitCode: exitCode))
            }
            // uv intentionally creates conventional 0755 virtualenv roots.
            // This runtime contains an app launch capability, so restore the
            // owner-only boundary established before invoking uv.
            guard chmod(staging, 0o700) == 0 else { return .failure(.ioFailure) }
            var installedDestination = false
            if rename(staging, destination) == 0 {
                ownsStaging = false
                installedDestination = true
            } else if errno == EEXIST || errno == ENOTEMPTY {
                guard validate(
                    runtimeDirectory: destination,
                    bridgeConfigPath: bridgeConfigPath,
                    homeDirectory: homeDirectory,
                    commandRunner: commandRunner
                ) else { return .failure(.existingRuntimeInvalid) }
            } else {
                return .failure(.ioFailure)
            }
            guard validate(
                runtimeDirectory: destination,
                bridgeConfigPath: bridgeConfigPath,
                homeDirectory: homeDirectory,
                commandRunner: commandRunner
            ) else {
                if installedDestination {
                    try? FileManager.default.removeItem(atPath: destination)
                }
                return .failure(.validationFailed)
            }
            return .success(executablePath(runtimeDirectory: destination))
        } catch {
            return .failure(.ioFailure)
        }
    }

    static func validate(
        runtimeDirectory: String,
        bridgeConfigPath: String,
        homeDirectory: String,
        commandRunner: CommandRunner = SharedOuroborosRuntimeProbe.run
    ) -> Bool {
        guard safeOwnerOnlyDirectory(runtimeDirectory) else { return false }
        let python = (runtimeDirectory as NSString).appendingPathComponent("bin/python")
        let executable = executablePath(runtimeDirectory: runtimeDirectory)
        guard safeOwnerExecutable(python), safeOwnerExecutable(executable) else { return false }
        let environment = [
            "HOME": homeDirectory,
            "OUROBOROS_MCP_CONFIG": bridgeConfigPath,
            "NO_COLOR": "1",
            "TERM": "dumb",
        ]
        let importScript = """
        import importlib.metadata as metadata
        import mcp
        import pygments.lexers.python
        assert metadata.version("ouroboros-ai") == "0.51.6"
        assert metadata.version("mcp").split(".", 1)[0] == "2"
        print("ourocode-managed-runtime-ok")
        """
        switch commandRunner(
            python,
            ["-I", "-c", importScript],
            8,
            environment
        ) {
        case .completed(let exitCode, let output):
            guard exitCode == 0, output.contains("ourocode-managed-runtime-ok") else { return false }
        case .timeout, .launchFailed:
            return false
        }
        switch commandRunner(
            executable,
            ["--version"],
            8,
            environment
        ) {
        case .completed(let exitCode, let output):
            guard SharedOuroborosRuntimeProbe.parseVersion(output, exitCode: exitCode)
                    == .value(SharedOuroborosResolver.requiredVersion) else { return false }
        case .timeout, .launchFailed:
            return false
        }
        // The exact distribution metadata, MCP major version, and the known
        // late-loaded Pygments module above are the durable runtime contract.
        // `mcp doctor` also inspects unrelated user-selected backends and can
        // fail or emit non-JSON diagnostics even when this profile is exact;
        // that broader probe already ran against uvx before materialization.
        return true
    }

    private static func executablePath(runtimeDirectory: String) -> String {
        (runtimeDirectory as NSString).appendingPathComponent("bin/ouroboros")
    }

    private static func installEnvironment(homeDirectory: String) -> [String: String] {
        [
            "HOME": homeDirectory,
            "NO_COLOR": "1",
            "TERM": "dumb",
            "UV_NO_CONFIG": "1",
            "UV_OFFLINE": "1",
            "UV_PYTHON_DOWNLOADS": "never",
        ]
    }

    private static func ensureOwnerOnlyDirectory(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  (info.st_mode & 0o077) == 0 else {
                throw ManagedOuroborosRuntimeFailure.invalidPaths
            }
            return
        }
        guard errno == ENOENT else { throw ManagedOuroborosRuntimeFailure.ioFailure }
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard safeOwnerOnlyDirectory(path) else {
            throw ManagedOuroborosRuntimeFailure.invalidPaths
        }
    }

    private static func safeOwnerOnlyDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_uid == getuid() &&
            (info.st_mode & 0o077) == 0
    }

    private static func safeOwnerExecutable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            // A relocatable uv venv may use a relative interpreter symlink;
            // resolve it and apply the executable checks to the target.
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved != path else { return false }
            var target = stat()
            return lstat(resolved, &target) == 0 &&
                (target.st_mode & S_IFMT) == S_IFREG &&
                (target.st_uid == getuid() || target.st_uid == 0) &&
                (target.st_mode & 0o022) == 0 &&
                (target.st_mode & 0o111) != 0
        }
        return (info.st_mode & S_IFMT) == S_IFREG &&
            info.st_uid == getuid() &&
            (info.st_mode & 0o022) == 0 &&
            (info.st_mode & 0o111) != 0
    }
}

enum SharedOuroborosStartupFailure: Error, Equatable {
    case invalidBridgeConfig
    case resolution(SharedOuroborosResolutionFailure)
    case runtimePreparation(ManagedOuroborosRuntimeFailure)
    case activation(SharedOuroborosActivationFailure)
}

/// One non-blocking startup attempt per application launch. This object never
/// installs or updates the user's Ouroboros; it may materialize the exact
/// app-owned MCP profile after a successful offline probe. It never touches
/// separately-owned stdio MCP processes registered by Claude or Codex.
final class SharedOuroborosServiceRuntime {
    typealias Completion = (Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure>) -> Void
    typealias StartOperation = (
        _ ouroborosPath: String,
        _ uvxPath: String?,
        _ bridgeConfigPath: String,
        _ homeDirectory: String
    ) -> Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure>
    typealias ExistingAttachOperation = (
        _ paths: SharedOuroborosServiceSupervisor.Paths
    ) -> Result<OuroborosManagedEndpoint?, SharedOuroborosActivationFailure>
    typealias ProbeOperation = (
        _ ouroborosPath: String,
        _ uvxPath: String?,
        _ bridgeConfigPath: String
    ) -> (OuroborosExecutableProbe, AuxiliaryExecutableProbe?)
    typealias ActivationOperation = (
        _ contract: OuroborosSharedLaunchContract,
        _ proposedBearerToken: String,
        _ paths: SharedOuroborosServiceSupervisor.Paths
    ) -> Result<OuroborosManagedEndpoint, SharedOuroborosActivationFailure>
    static let shared = SharedOuroborosServiceRuntime()
    private static let logger = Logger(
        subsystem: "com.ourolabs.ourocode",
        category: "shared-ouroboros"
    )

    private struct StartRequest {
        let ouroborosPath: String
        let uvxPath: String?
        let bridgeConfigPath: String
        let homeDirectory: String
    }

    private let queue: DispatchQueue
    private let startOperation: StartOperation?
    private let existingAttachOperation: ExistingAttachOperation?
    private let probeOperation: ProbeOperation?
    private let activationOperation: ActivationOperation?
    private let lock = NSLock()
    private var running = false
    private var settledResult: Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure>?
    private var waiters: [Completion] = []
    private var lastRequest: StartRequest?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.ourolabs.ourocode.ouroboros-shared-startup",
            qos: .utility
        ),
        startOperation: StartOperation? = nil,
        existingAttachOperation: ExistingAttachOperation? = nil,
        probeOperation: ProbeOperation? = nil,
        activationOperation: ActivationOperation? = nil
    ) {
        self.queue = queue
        self.startOperation = startOperation
        self.existingAttachOperation = existingAttachOperation
        self.probeOperation = probeOperation
        self.activationOperation = activationOperation
    }

    func whenSettled(_ completion: @escaping Completion) {
        lock.lock()
        if let result = settledResult {
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        } else {
            waiters.append(completion)
            lock.unlock()
        }
    }

    func start(
        ouroborosPath: String,
        uvxPath: String?,
        bridgeConfigPath: String,
        homeDirectory: String,
        completion: Completion? = nil
    ) {
        let request = StartRequest(
            ouroborosPath: ouroborosPath,
            uvxPath: uvxPath,
            bridgeConfigPath: bridgeConfigPath,
            homeDirectory: homeDirectory
        )
        lock.lock()
        lastRequest = request
        if let result = settledResult {
            lock.unlock()
            if let completion { DispatchQueue.main.async { completion(result) } }
            return
        }
        if let completion { waiters.append(completion) }
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        enqueue(request)
    }

    /// Repeats the exact previously validated startup request after a transient
    /// probe or launchd failure. A retry never discovers a different binary,
    /// endpoint, bridge config, or working directory.
    func retry(completion: Completion? = nil) {
        lock.lock()
        if let result = settledResult, case .success = result {
            lock.unlock()
            if let completion { DispatchQueue.main.async { completion(result) } }
            return
        }
        guard let request = lastRequest else {
            lock.unlock()
            if let completion {
                DispatchQueue.main.async { completion(.failure(.invalidBridgeConfig)) }
            }
            return
        }
        if let completion { waiters.append(completion) }
        settledResult = nil
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        enqueue(request)
    }

    private func enqueue(_ request: StartRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure>
            if let startOperation = self.startOperation {
                result = startOperation(
                    request.ouroborosPath,
                    request.uvxPath,
                    request.bridgeConfigPath,
                    request.homeDirectory
                )
            } else {
                result = self.startSynchronously(
                    ouroborosPath: request.ouroborosPath,
                    uvxPath: request.uvxPath,
                    bridgeConfigPath: request.bridgeConfigPath,
                    homeDirectory: request.homeDirectory
                )
            }
            if case .failure(let failure) = result {
                Self.logger.error(
                    "startup_failed code=\(Self.redactedLogCode(failure), privacy: .public)"
                )
            }
            self.lock.lock()
            self.running = false
            self.settledResult = result
            let waiters = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            self.lock.unlock()
            DispatchQueue.main.async { waiters.forEach { $0(result) } }
        }
    }

    private func startSynchronously(
        ouroborosPath: String,
        uvxPath: String?,
        bridgeConfigPath: String,
        homeDirectory: String
    ) -> Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure> {
        guard SharedOuroborosResolver.isCanonicalAbsolutePath(homeDirectory) else {
            return .failure(.invalidBridgeConfig)
        }
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: (homeDirectory as NSString).appendingPathComponent("Library/LaunchAgents"),
            contractDirectory: (homeDirectory as NSString).appendingPathComponent("Library/Application Support/Ourocode")
        )
        let existingAttach = existingAttachOperation?(paths) ??
            SharedOuroborosServiceSupervisor().attachToExistingService(paths: paths)
        switch existingAttach {
        case .success(.some(let managedEndpoint)):
            return .success(managedEndpoint)
        case .success(nil):
            break
        case .failure(let failure):
            return .failure(.activation(failure))
        }

        let supervisor = SharedOuroborosServiceSupervisor()
        switch supervisor.retireLegacyUnauthenticatedService(paths: paths) {
        case .success:
            break
        case .failure(let failure):
            return .failure(.activation(failure))
        }

        guard Self.isSafeBridgeConfig(at: bridgeConfigPath) else {
            return .failure(.invalidBridgeConfig)
        }
        let probes = probeOperation?(
            ouroborosPath,
            uvxPath,
            bridgeConfigPath
        ) ?? SharedOuroborosRuntimeProbe.inspect(
            ouroborosPath: ouroborosPath,
            uvxPath: uvxPath,
            bridgeConfigPath: bridgeConfigPath
        )
        let resolution = SharedOuroborosResolver.resolve(.init(
            executableOverride: nil,
            installedOuroboros: probes.0,
            uvx: probes.1,
            bridgeConfigPath: paths.bridgeConfigPath,
            workingDirectory: homeDirectory
        ))
        var contract: OuroborosSharedLaunchContract
        switch resolution {
        case .success(let value): contract = value
        case .failure(let failure): return .failure(.resolution(failure))
        }
        if contract.invocation == .isolatedUVX {
            guard let uvxPath else {
                return .failure(.runtimePreparation(.uvUnavailable))
            }
            let prepared = ManagedOuroborosRuntimeMaterializer.prepare(
                uvxPath: uvxPath,
                contractDirectory: paths.contractDirectory,
                bridgeConfigPath: bridgeConfigPath,
                homeDirectory: homeDirectory
            )
            let managedExecutable: String
            switch prepared {
            case .success(let path): managedExecutable = path
            case .failure(let failure): return .failure(.runtimePreparation(failure))
            }
            switch SharedOuroborosResolver.pinManagedRuntime(
                contract,
                executablePath: managedExecutable
            ) {
            case .success(let pinned): contract = pinned
            case .failure(let failure): return .failure(.resolution(failure))
            }
        }

        let proposedBearerToken = SharedOuroborosBearerToken.generate()
        guard SharedOuroborosBearerToken.isValid(proposedBearerToken) else {
            return .failure(.activation(.invalidContract))
        }
        let activation = activationOperation?(contract, proposedBearerToken, paths) ??
            SharedOuroborosServiceSupervisor().activateSharedService(
                contract: contract,
                proposedBearerToken: proposedBearerToken,
                paths: paths
            )
        switch activation {
        case .success(let managedEndpoint): return .success(managedEndpoint)
        case .failure(let failure): return .failure(.activation(failure))
        }
    }

    private static func redactedLogCode(_ failure: SharedOuroborosStartupFailure) -> String {
        switch failure {
        case .invalidBridgeConfig:
            return "invalid_bridge_config"
        case .resolution(let resolution):
            return "resolution.\(redactedResolutionCode(resolution))"
        case .runtimePreparation(let preparation):
            return "runtime_preparation.\(redactedRuntimePreparationCode(preparation))"
        case .activation(let activation):
            return "activation.\(redactedActivationCode(activation))"
        }
    }

    private static func redactedRuntimePreparationCode(
        _ failure: ManagedOuroborosRuntimeFailure
    ) -> String {
        switch failure {
        case .invalidPaths: return "invalid_paths"
        case .uvUnavailable: return "uv_unavailable"
        case .installTimedOut: return "install_timed_out"
        case .installFailed: return "install_failed"
        case .existingRuntimeInvalid: return "existing_runtime_invalid"
        case .validationFailed: return "validation_failed"
        case .ioFailure: return "io_failure"
        }
    }

    private static func redactedResolutionCode(_ failure: SharedOuroborosResolutionFailure) -> String {
        switch failure {
        case .unavailable: return "unavailable"
        case .invalidOverride: return "invalid_override"
        case .executableNotAbsolute: return "executable_not_absolute"
        case .executableUnavailable: return "executable_unavailable"
        case .versionProbeTimedOut: return "version_probe_timed_out"
        case .versionProbeMalformed: return "version_probe_malformed"
        case .versionProbeFailed: return "version_probe_failed"
        case .wrongVersion: return "wrong_version"
        case .doctorTimedOut: return "doctor_timed_out"
        case .doctorMalformed: return "doctor_malformed"
        case .doctorFailed: return "doctor_failed"
        case .mcpV2Unsupported: return "mcp_v2_unsupported"
        case .uvxUnavailable: return "uvx_unavailable"
        case .uvxProbeTimedOut: return "uvx_probe_timed_out"
        case .uvxProbeMalformed: return "uvx_probe_malformed"
        case .uvxProbeFailed: return "uvx_probe_failed"
        case .uvxMCPV2Unsupported: return "uvx_mcp_v2_unsupported"
        case .bridgeConfigInvalid: return "bridge_config_invalid"
        }
    }

    private static func redactedActivationCode(_ failure: SharedOuroborosActivationFailure) -> String {
        switch failure {
        case .invalidContract: return "invalid_contract"
        case .invalidPaths: return "invalid_paths"
        case .existingPlistConflicts: return "existing_plist_conflicts"
        case .existingContractConflicts: return "existing_contract_conflicts"
        case .existingBridgeConfigConflicts: return "existing_bridge_config_conflicts"
        case .unsafeExistingArtifact: return "unsafe_existing_artifact"
        case .ioFailure: return "io_failure"
        case .launchctlTimedOut: return "launchctl_timed_out"
        case .launchctlFailed: return "launchctl_failed"
        case .readinessTimedOut: return "readiness_timed_out"
        case .endpointAlreadyOccupied: return "endpoint_already_occupied"
        }
    }

    static func isSafeBridgeConfig(at path: String) -> Bool {
        guard SharedOuroborosResolver.isCanonicalAbsolutePath(path) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o022) == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              SharedOuroborosBridgeConfig.matches(data) else { return false }
        return info.st_size == data.count
    }
}

enum SharedOuroborosActivationFailure: Error, Equatable {
    case invalidContract
    case invalidPaths
    case existingPlistConflicts
    case existingContractConflicts
    case existingBridgeConfigConflicts
    case unsafeExistingArtifact
    case ioFailure
    case launchctlTimedOut
    case launchctlFailed(exitCode: Int32)
    case readinessTimedOut
    case endpointAlreadyOccupied
}

enum SharedOuroborosExistingArtifact: Equatable {
    case missing
    case exact(Data)
}

struct SharedOuroborosActivationPlan: Equatable {
    let plistData: Data
    let contractData: Data
    let bearerToken: String
    let shouldWritePlist: Bool
    let shouldWriteContract: Bool
}

/// Shared loopback activation. This type deliberately has no install,
/// bootout, kill, replacement, or stdio child-process ownership API.
final class SharedOuroborosServiceSupervisor {
    struct Paths: Equatable {
        let launchAgentsDirectory: String
        let contractDirectory: String

        var plistPath: String {
            (launchAgentsDirectory as NSString).appendingPathComponent(
                SharedOuroborosResolver.sharedLaunchdLabel + ".plist"
            )
        }

        var contractPath: String {
            (contractDirectory as NSString).appendingPathComponent(
                SharedOuroborosResolver.sharedLaunchdLabel + ".json"
            )
        }

        func legacyPlistPath(label: String) -> String {
            (launchAgentsDirectory as NSString).appendingPathComponent(
                label + ".plist"
            )
        }

        func legacyContractPath(label: String) -> String {
            (contractDirectory as NSString).appendingPathComponent(
                label + ".json"
            )
        }

        var legacyEmptyBridgeConfigPath: String {
            (contractDirectory as NSString).appendingPathComponent(
                "ouroboros-mcp-bridge-empty-v1.yaml"
            )
        }


        var bridgeConfigPath: String {
            (contractDirectory as NSString).appendingPathComponent(
                SharedOuroborosBridgeConfig.fileName
            )
        }
    }

    struct ReadinessPolicy: Equatable {
        let maximumAttempts: Int
        let interval: TimeInterval
        let probeTimeout: TimeInterval
        let maximumDuration: TimeInterval

        static let boundedDefault = ReadinessPolicy(
            maximumAttempts: 120,
            interval: 0.25,
            probeTimeout: 0.5,
            maximumDuration: 30
        )

        static let boundedExistingAttach = ReadinessPolicy(
            maximumAttempts: 4,
            interval: 0.1,
            probeTimeout: 0.5,
            maximumDuration: 2
        )

        fileprivate var isBounded: Bool {
            maximumAttempts > 0 && maximumAttempts <= 120 &&
                interval >= 0 && interval <= 0.5 &&
                probeTimeout > 0 && probeTimeout <= 1 &&
                maximumDuration > 0 && maximumDuration <= 30
        }
    }

    enum LaunchctlResult: Equatable {
        case launched
        case alreadyExists
        case notFound
        case timeout
        case failed(exitCode: Int32)
    }

    typealias LaunchctlRunner = (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> LaunchctlResult
    typealias ReadinessProbe = (
        _ endpoint: URL,
        _ bearerToken: String,
        _ timeout: TimeInterval
    ) -> Bool

    /// Retire only exact Ourocode-owned predecessors. Every artifact pair is
    /// validated before the first launchctl call, so one partial or edited
    /// record prevents any migration. The old files remain as an audit trail;
    /// v5 gets a separate immutable CUA-enabled contract and credential.
    func retireLegacyUnauthenticatedService(
        paths: Paths,
        launchctlRunner: LaunchctlRunner = SharedOuroborosServiceSupervisor.runLaunchctl
    ) -> Result<Void, SharedOuroborosActivationFailure> {
        do {
            let currentPlist = try readArtifact(at: paths.plistPath)
            let currentContract = try readArtifact(at: paths.contractPath)
            switch (currentPlist, currentContract) {
            case (.exact, .exact):
                // A retained current contract does not prove that its process
                // owns the shared port. Exact predecessor jobs may still be
                // loaded and can win the bind race after login. Continue
                // validating and retiring those owner-only jobs before the
                // current service is attached or restarted.
                break
            case (.missing, .missing):
                break
            default:
                return .failure(.existingPlistConflicts)
            }

            var labelsToRetire: [String] = []
            for legacy in SharedOuroborosResolver.knownLegacyServices {
                let legacyPlist = try readArtifact(
                    at: paths.legacyPlistPath(label: legacy.label)
                )
                let legacyContract = try readArtifact(
                    at: paths.legacyContractPath(label: legacy.label)
                )
                switch (legacyPlist, legacyContract) {
                case (.missing, .missing):
                    continue
                case (.exact(let plistData), .exact(let contractData)):
                    guard let contract = try? JSONDecoder().decode(
                              OuroborosSharedLaunchContract.self,
                              from: contractData
                          ),
                          Self.isExactLegacyContract(
                              contract,
                              expectedLabel: legacy.label,
                              expectedVersion: legacy.version,
                              paths: paths
                          ),
                          Self.makeContractData(contract) == contractData,
                          let expectedPlist = Self.makeLegacyPlistData(
                              contract: contract,
                              expectedLabel: legacy.label
                          ),
                          Self.propertyListsMatch(plistData, expectedPlist) else {
                        return .failure(.existingContractConflicts)
                    }
                    labelsToRetire.append(legacy.label)
                default:
                    return .failure(.existingContractConflicts)
                }
            }

            // v3 added a bearer token but still launched uvx directly. Retire
            // only a byte-for-byte, owner-only v3 pair; an edited or partial
            // pair must never be booted out on someone else's behalf.
            let authenticatedLegacyPlist = try readArtifact(
                at: paths.legacyPlistPath(label: SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel)
            )
            let authenticatedLegacyContract = try readArtifact(
                at: paths.legacyContractPath(label: SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel)
            )
            switch (authenticatedLegacyPlist, authenticatedLegacyContract) {
            case (.missing, .missing):
                break
            case (.exact(let plistData), .exact(let contractData)):
                guard let contract = try? JSONDecoder().decode(
                          OuroborosSharedLaunchContract.self,
                          from: contractData
                      ),
                      Self.isExactAuthenticatedLegacyContract(contract, paths: paths),
                      Self.makeContractData(contract) == contractData,
                      let bearerToken = Self.bearerToken(fromPlistData: plistData),
                      let expectedPlist = Self.makeAuthenticatedLegacyPlistData(
                          contract: contract,
                          bearerToken: bearerToken,
                          paths: paths
                      ),
                      Self.propertyListsMatch(plistData, expectedPlist) else {
                    return .failure(.existingContractConflicts)
                }
                labelsToRetire.append(SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel)
            default:
                return .failure(.existingContractConflicts)
            }

            // v4 was the first managed runtime, but its bridge was deliberately
            // empty. Retire it only when the contract, credential, plist and
            // empty bridge all match the exact prior release contract.
            let runtimeV4Label = SharedOuroborosResolver.legacyRuntimeV4LaunchdLabel
            let runtimeV4Plist = try readArtifact(
                at: paths.legacyPlistPath(label: runtimeV4Label)
            )
            let runtimeV4Contract = try readArtifact(
                at: paths.legacyContractPath(label: runtimeV4Label)
            )
            let runtimeV4Bridge = try readArtifact(at: paths.legacyEmptyBridgeConfigPath)
            switch (runtimeV4Plist, runtimeV4Contract) {
            case (.missing, .missing):
                break
            case (.exact(let plistData), .exact(let contractData)):
                guard case .exact(let bridgeData) = runtimeV4Bridge,
                      bridgeData == Data("mcp_servers: []\n".utf8),
                      let contract = try? JSONDecoder().decode(
                          OuroborosSharedLaunchContract.self,
                          from: contractData
                      ),
                      Self.isExactRuntimeV4Contract(contract, paths: paths),
                      Self.makeContractData(contract) == contractData,
                      let bearerToken = Self.bearerToken(fromPlistData: plistData),
                      let expectedPlist = Self.makeRuntimeV4PlistData(
                          contract: contract,
                          bearerToken: bearerToken,
                          paths: paths
                      ),
                      Self.propertyListsMatch(plistData, expectedPlist) else {
                    return .failure(.existingContractConflicts)
                }
                labelsToRetire.append(runtimeV4Label)
            default:
                return .failure(.existingContractConflicts)
            }

            for label in labelsToRetire {
                switch launchctlRunner(
                    "/bin/launchctl",
                    ["bootout", "gui/\(getuid())/\(label)"],
                    3
                ) {
                case .launched, .notFound:
                    continue
                case .alreadyExists:
                    return .failure(.existingContractConflicts)
                case .timeout:
                    return .failure(.launchctlTimedOut)
                case .failed(let exitCode):
                    return .failure(.launchctlFailed(exitCode: exitCode))
                }
            }
            return .success(())
        } catch let failure as SharedOuroborosActivationFailure {
            return .failure(failure)
        } catch {
            return .failure(.ioFailure)
        }
    }

    /// Read-only fast path for later app processes. The three owner-only
    /// artifacts are the cross-process ownership record; an exact live
    /// handshake proves that the retained endpoint still matches that record.
    /// No executable probe, file write, or launchctl operation occurs here.
    func attachToExistingService(
        paths: Paths,
        readinessPolicy: ReadinessPolicy = .boundedExistingAttach,
        readinessProbe: ReadinessProbe = SharedOuroborosServiceSupervisor.probeReadiness
    ) -> Result<OuroborosManagedEndpoint?, SharedOuroborosActivationFailure> {
        guard readinessPolicy.isBounded,
              validDirectoryPath(paths.launchAgentsDirectory),
              validDirectoryPath(paths.contractDirectory) else {
            return .failure(.invalidPaths)
        }

        do {
            let bridgeArtifact = try readArtifact(at: paths.bridgeConfigPath)
            let plistArtifact = try readArtifact(at: paths.plistPath)
            let contractArtifact = try readArtifact(at: paths.contractPath)
            guard case .exact(let bridgeData) = bridgeArtifact,
                  case .exact(let plistData) = plistArtifact,
                  case .exact(let contractData) = contractArtifact else {
                return .success(nil)
            }
            guard SharedOuroborosBridgeConfig.matches(bridgeData) else {
                return .failure(.existingBridgeConfigConflicts)
            }
            guard let contract = try? JSONDecoder().decode(
                OuroborosSharedLaunchContract.self,
                from: contractData
            ),
            SharedOuroborosResolver.validate(contract),
            contract.bridgeConfigPath == paths.bridgeConfigPath,
            let canonicalContract = Self.makeContractData(contract),
            canonicalContract == contractData else {
                return .failure(.existingContractConflicts)
            }
            guard let bearerToken = Self.bearerToken(fromPlistData: plistData),
                  let expectedPlist = Self.makePlistData(
                      contract: contract,
                      bearerToken: bearerToken
                  ),
                  Self.propertyListsMatch(plistData, expectedPlist) else {
                return .failure(.existingPlistConflicts)
            }

            let deadline = Date().addingTimeInterval(readinessPolicy.maximumDuration)
            for attempt in 0 ..< readinessPolicy.maximumAttempts {
                let remainingBeforeProbe = deadline.timeIntervalSinceNow
                guard remainingBeforeProbe > 0 else { break }
                if readinessProbe(
                    contract.endpoint,
                    bearerToken,
                    min(readinessPolicy.probeTimeout, remainingBeforeProbe)
                ) {
                    guard let endpoint = OuroborosManagedEndpoint(
                        endpoint: contract.endpoint,
                        bearerToken: bearerToken
                    ) else { return .failure(.existingPlistConflicts) }
                    return .success(endpoint)
                }
                let remainingAfterProbe = deadline.timeIntervalSinceNow
                if attempt + 1 < readinessPolicy.maximumAttempts,
                   readinessPolicy.interval > 0,
                   remainingAfterProbe > 0 {
                    usleep(useconds_t(min(readinessPolicy.interval, remainingAfterProbe) * 1_000_000))
                }
            }
            return .success(nil)
        } catch let failure as SharedOuroborosActivationFailure {
            return .failure(failure)
        } catch {
            return .failure(.ioFailure)
        }
    }

    static func activationPlan(
        contract: OuroborosSharedLaunchContract,
        proposedBearerToken: String,
        existingPlist: SharedOuroborosExistingArtifact,
        existingContract: SharedOuroborosExistingArtifact
    ) -> Result<SharedOuroborosActivationPlan, SharedOuroborosActivationFailure> {
        guard SharedOuroborosResolver.validate(contract),
              SharedOuroborosBearerToken.isValid(proposedBearerToken),
              let contractData = makeContractData(contract) else {
            return .failure(.invalidContract)
        }

        let bearerToken: String
        let plistData: Data
        let writePlist: Bool
        switch existingPlist {
        case .missing:
            bearerToken = proposedBearerToken
            guard let generated = makePlistData(
                contract: contract,
                bearerToken: bearerToken
            ) else { return .failure(.invalidContract) }
            plistData = generated
            writePlist = true
        case .exact(let data):
            // PropertyListSerialization does not promise stable dictionary
            // key order between processes. Requiring byte identity made the
            // app reject its own unchanged launchd contract after relaunch.
            // Compare the decoded value tree; permissions, ownership, and the
            // regular-file/no-symlink checks remain enforced by readArtifact.
            guard let existingBearerToken = Self.bearerToken(fromPlistData: data),
                  let expected = makePlistData(
                      contract: contract,
                      bearerToken: existingBearerToken
                  ),
                  propertyListsMatch(data, expected) else {
                return .failure(.existingPlistConflicts)
            }
            bearerToken = existingBearerToken
            plistData = expected
            writePlist = false
        }

        let writeContract: Bool
        switch existingContract {
        case .missing:
            writeContract = true
        case .exact(let data):
            guard data == contractData else { return .failure(.existingContractConflicts) }
            writeContract = false
        }

        return .success(SharedOuroborosActivationPlan(
            plistData: plistData,
            contractData: contractData,
            bearerToken: bearerToken,
            shouldWritePlist: writePlist,
            shouldWriteContract: writeContract
        ))
    }

    /// Ouroboros itself is launched and retained by the user's launchd domain;
    /// the app only waits for the short-lived launchctl command. Call this from
    /// a worker queue because bounded readiness polling is intentionally
    /// synchronous.
    func activateSharedService(
        contract: OuroborosSharedLaunchContract,
        proposedBearerToken: String,
        paths: Paths,
        readinessPolicy: ReadinessPolicy = .boundedDefault,
        launchctlRunner: LaunchctlRunner = SharedOuroborosServiceSupervisor.runLaunchctl,
        readinessProbe: ReadinessProbe = SharedOuroborosServiceSupervisor.probeReadiness
    ) -> Result<OuroborosManagedEndpoint, SharedOuroborosActivationFailure> {
        guard readinessPolicy.isBounded,
              validDirectoryPath(paths.launchAgentsDirectory),
              validDirectoryPath(paths.contractDirectory) else {
            return .failure(.invalidPaths)
        }

        do {
            try ensureDirectory(paths.launchAgentsDirectory)
            try ensureDirectory(paths.contractDirectory)
            guard contract.bridgeConfigPath == paths.bridgeConfigPath else {
                return .failure(.invalidContract)
            }
            let bridgeArtifact = try readArtifact(at: paths.bridgeConfigPath)
            switch bridgeArtifact {
            case .missing:
                try writeOwnerOnlyAtomicallyWithoutReplacement(
                    SharedOuroborosBridgeConfig.data,
                    to: paths.bridgeConfigPath,
                    conflict: .existingBridgeConfigConflicts
                )
            case .exact(let data):
                guard SharedOuroborosBridgeConfig.matches(data) else {
                    return .failure(.existingBridgeConfigConflicts)
                }
            }
            let plistArtifact = try readArtifact(at: paths.plistPath)
            let contractArtifact = try readArtifact(at: paths.contractPath)
            let planned = Self.activationPlan(
                contract: contract,
                proposedBearerToken: proposedBearerToken,
                existingPlist: plistArtifact,
                existingContract: contractArtifact
            )
            let plan: SharedOuroborosActivationPlan
            switch planned {
            case .success(let value): plan = value
            case .failure(let failure): return .failure(failure)
            }

            if readinessProbe(
                contract.endpoint,
                plan.bearerToken,
                readinessPolicy.probeTimeout
            ) {
                // An exact server with no exact ownership artifacts may be a
                // manually launched or differently managed process. Do not
                // claim it or install a competing launchd job on the same port.
                guard !plan.shouldWritePlist, !plan.shouldWriteContract else {
                    return .failure(.endpointAlreadyOccupied)
                }
                guard let endpoint = OuroborosManagedEndpoint(
                    endpoint: contract.endpoint,
                    bearerToken: plan.bearerToken
                ) else { return .failure(.invalidContract) }
                return .success(endpoint)
            }

            if plan.shouldWritePlist {
                try writeOwnerOnlyAtomicallyWithoutReplacement(
                    plan.plistData,
                    to: paths.plistPath,
                    conflict: .existingPlistConflicts
                )
            }
            if plan.shouldWriteContract {
                try writeOwnerOnlyAtomicallyWithoutReplacement(
                    plan.contractData,
                    to: paths.contractPath,
                    conflict: .existingContractConflicts
                )
            }

            let launchResult = launchctlRunner(
                "/bin/launchctl",
                ["bootstrap", "gui/\(getuid())", paths.plistPath],
                3
            )
            switch launchResult {
            case .launched:
                break
            case .alreadyExists:
                guard try artifactsExactlyMatch(contract: contract, paths: paths) else {
                    return .failure(.existingContractConflicts)
                }
            case .notFound:
                return .failure(.launchctlFailed(exitCode: ESRCH))
            case .timeout:
                return .failure(.launchctlTimedOut)
            case .failed(let exitCode):
                return .failure(.launchctlFailed(exitCode: exitCode))
            }

            let readinessDeadline = Date().addingTimeInterval(readinessPolicy.maximumDuration)
            for attempt in 0 ..< readinessPolicy.maximumAttempts {
                let remainingBeforeProbe = readinessDeadline.timeIntervalSinceNow
                guard remainingBeforeProbe > 0 else { break }
                if readinessProbe(
                    contract.endpoint,
                    plan.bearerToken,
                    min(readinessPolicy.probeTimeout, remainingBeforeProbe)
                ) {
                    guard let endpoint = OuroborosManagedEndpoint(
                        endpoint: contract.endpoint,
                        bearerToken: plan.bearerToken
                    ) else { return .failure(.invalidContract) }
                    return .success(endpoint)
                }
                let remainingAfterProbe = readinessDeadline.timeIntervalSinceNow
                if attempt + 1 < readinessPolicy.maximumAttempts,
                   readinessPolicy.interval > 0,
                   remainingAfterProbe > 0 {
                    let sleepInterval = min(readinessPolicy.interval, remainingAfterProbe)
                    usleep(useconds_t(sleepInterval * 1_000_000))
                }
            }
            return .failure(.readinessTimedOut)
        } catch let failure as SharedOuroborosActivationFailure {
            return .failure(failure)
        } catch {
            return .failure(.ioFailure)
        }
    }

    private func validDirectoryPath(_ path: String) -> Bool {
        SharedOuroborosResolver.isCanonicalAbsolutePath(path)
    }

    private func ensureDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw SharedOuroborosActivationFailure.invalidPaths }
            return
        }
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func readArtifact(at path: String) throws -> SharedOuroborosExistingArtifact {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return .missing }
            throw SharedOuroborosActivationFailure.ioFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw SharedOuroborosActivationFailure.unsafeExistingArtifact
        }
        return .exact(try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]))
    }

    private func writeOwnerOnlyAtomicallyWithoutReplacement(
        _ data: Data,
        to path: String,
        conflict: SharedOuroborosActivationFailure
    ) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporaryPath = (directory as NSString).appendingPathComponent(
            ".\(name).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SharedOuroborosActivationFailure.ioFailure }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporaryPath) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                guard count > 0 else { throw SharedOuroborosActivationFailure.ioFailure }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
        }
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o600) == 0 else {
            throw SharedOuroborosActivationFailure.ioFailure
        }
        guard link(temporaryPath, path) == 0 else {
            if errno == EEXIST { throw conflict }
            throw SharedOuroborosActivationFailure.ioFailure
        }
        shouldRemoveTemporary = false
        unlink(temporaryPath)
    }

    private func artifactsExactlyMatch(contract: OuroborosSharedLaunchContract, paths: Paths) throws -> Bool {
        guard let expectedContract = Self.makeContractData(contract),
              case .exact(let existingPlist) = try readArtifact(at: paths.plistPath),
              let bearerToken = Self.bearerToken(fromPlistData: existingPlist),
              let expectedPlist = Self.makePlistData(
                  contract: contract,
                  bearerToken: bearerToken
              ),
              Self.propertyListsMatch(existingPlist, expectedPlist),
              case .exact(let existingContract) = try readArtifact(at: paths.contractPath) else {
            return false
        }
        return existingContract == expectedContract
    }

    private static func makeContractData(_ contract: OuroborosSharedLaunchContract) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(contract)
    }


    private static func propertyListsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, format: nil),
              let right = try? PropertyListSerialization.propertyList(from: rhs, format: nil),
              let leftDictionary = left as? [String: Any],
              let rightDictionary = right as? [String: Any] else { return false }
        return NSDictionary(dictionary: leftDictionary).isEqual(to: rightDictionary)
    }

    private static func bearerToken(fromPlistData data: Data) -> String? {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let environment = values["EnvironmentVariables"] as? [String: String],
              let bearerToken = environment[SharedOuroborosBearerToken.environmentKey],
              SharedOuroborosBearerToken.isValid(bearerToken) else { return nil }
        return bearerToken
    }

    private static func isExactLegacyContract(
        _ contract: OuroborosSharedLaunchContract,
        expectedLabel: String,
        expectedVersion: OuroborosServiceVersion,
        paths: Paths
    ) -> Bool {
        guard contract.schemaVersion == 2,
              contract.launchdLabel == expectedLabel,
              contract.serviceVersion == expectedVersion,
              contract.endpoint == SharedOuroborosResolver.defaultEndpoint,
              contract.endpointTrust == .localUnauthenticated,
              (contract.bridgeConfigPath == paths.legacyEmptyBridgeConfigPath
                || contract.bridgeConfigPath == paths.bridgeConfigPath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.executablePath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.workingDirectory),
              contract.workingDirectory != "/" else { return false }
        switch contract.invocation {
        case .installedOuroboros:
            return contract.arguments == SharedOuroborosResolver.directArguments
        case .isolatedUVX:
            return contract.arguments == legacyIsolatedUVXArguments(version: expectedVersion)
        case .managedToolRuntime:
            return false
        }
    }

    private static func isExactAuthenticatedLegacyContract(
        _ contract: OuroborosSharedLaunchContract,
        paths: Paths
    ) -> Bool {
        guard contract.schemaVersion == 3,
              contract.launchdLabel == SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel,
              contract.serviceVersion == SharedOuroborosResolver.requiredVersion,
              contract.endpoint == SharedOuroborosResolver.defaultEndpoint,
              contract.endpointTrust == .managedAuthenticated,
              (contract.bridgeConfigPath == paths.legacyEmptyBridgeConfigPath
                || contract.bridgeConfigPath == paths.bridgeConfigPath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.executablePath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.workingDirectory),
              contract.workingDirectory != "/" else { return false }
        switch contract.invocation {
        case .installedOuroboros:
            return contract.arguments == SharedOuroborosResolver.directArguments
        case .isolatedUVX:
            return contract.arguments == SharedOuroborosResolver.isolatedUVXArguments
        case .managedToolRuntime:
            return false
        }
    }

    private static func isExactRuntimeV4Contract(
        _ contract: OuroborosSharedLaunchContract,
        paths: Paths
    ) -> Bool {
        guard contract.schemaVersion == 4,
              contract.launchdLabel == SharedOuroborosResolver.legacyRuntimeV4LaunchdLabel,
              contract.serviceVersion == SharedOuroborosResolver.requiredVersion,
              contract.endpoint == SharedOuroborosResolver.defaultEndpoint,
              contract.endpointTrust == .managedAuthenticated,
              contract.bridgeConfigPath == paths.legacyEmptyBridgeConfigPath,
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.executablePath),
              SharedOuroborosResolver.isCanonicalAbsolutePath(contract.workingDirectory),
              contract.workingDirectory != "/" else { return false }
        switch contract.invocation {
        case .installedOuroboros, .managedToolRuntime:
            return contract.arguments == SharedOuroborosResolver.directArguments
        case .isolatedUVX:
            return false
        }
    }

    private static func legacyIsolatedUVXArguments(
        version: OuroborosServiceVersion
    ) -> [String] {
        SharedOuroborosResolver.isolatedUVXPrefixArguments.dropLast(2) + [
            "--from", "ouroboros-ai[mcp]==\(version)",
            "ouroboros", "mcp", "serve",
            "--runtime", "codex",
            "--transport", "streamable-http",
            "--host", "127.0.0.1",
            "--port", "8976",
        ]
    }

    private static func makeLegacyPlistData(
        contract: OuroborosSharedLaunchContract,
        expectedLabel: String
    ) -> Data? {
        guard contract.schemaVersion == 2,
              contract.launchdLabel == expectedLabel,
              contract.endpointTrust == .localUnauthenticated else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: [
                "Label": contract.launchdLabel,
                "ProgramArguments": contract.programArguments,
                "WorkingDirectory": contract.workingDirectory,
                "EnvironmentVariables": [
                    "OUROBOROS_MCP_CONFIG": contract.bridgeConfigPath,
                    "HOME": contract.workingDirectory,
                ],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            ],
            format: .xml,
            options: 0
        )
    }

    private static func makeAuthenticatedLegacyPlistData(
        contract: OuroborosSharedLaunchContract,
        bearerToken: String,
        paths: Paths
    ) -> Data? {
        guard isExactAuthenticatedLegacyContract(contract, paths: paths),
              SharedOuroborosBearerToken.isValid(bearerToken) else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: [
                "Label": contract.launchdLabel,
                "ProgramArguments": contract.programArguments,
                "WorkingDirectory": contract.workingDirectory,
                "EnvironmentVariables": [
                    "OUROBOROS_MCP_CONFIG": contract.bridgeConfigPath,
                    SharedOuroborosBearerToken.environmentKey: bearerToken,
                    "HOME": contract.workingDirectory,
                ],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            ],
            format: .xml,
            options: 0
        )
    }

    private static func makeRuntimeV4PlistData(
        contract: OuroborosSharedLaunchContract,
        bearerToken: String,
        paths: Paths
    ) -> Data? {
        guard isExactRuntimeV4Contract(contract, paths: paths),
              SharedOuroborosBearerToken.isValid(bearerToken) else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: [
                "Label": contract.launchdLabel,
                "ProgramArguments": contract.programArguments,
                "WorkingDirectory": contract.workingDirectory,
                "EnvironmentVariables": [
                    "OUROBOROS_MCP_CONFIG": contract.bridgeConfigPath,
                    SharedOuroborosBearerToken.environmentKey: bearerToken,
                    "HOME": contract.workingDirectory,
                ],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            ],
            format: .xml,
            options: 0
        )
    }

    private static func makePlistData(
        contract: OuroborosSharedLaunchContract,
        bearerToken: String
    ) -> Data? {
        guard SharedOuroborosResolver.validate(contract),
              SharedOuroborosBearerToken.isValid(bearerToken) else { return nil }
        let values: [String: Any] = [
            "Label": contract.launchdLabel,
            "ProgramArguments": contract.programArguments,
            // launchd otherwise starts agents at `/`. Ouroboros session
            // discovery is workspace-aware; scanning from the filesystem root
            // made the all-session projection hang and balloon memory.
            "WorkingDirectory": contract.workingDirectory,
            "EnvironmentVariables": [
                "OUROBOROS_MCP_CONFIG": contract.bridgeConfigPath,
                SharedOuroborosBearerToken.environmentKey: bearerToken,
                "HOME": contract.workingDirectory,
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        )
    }

    private static func runLaunchctl(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> LaunchctlResult {
        guard executablePath == "/bin/launchctl", timeout > 0, timeout <= 3 else { return .failed(exitCode: EINVAL) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return .failed(exitCode: Int32(errno)) }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        guard !process.isRunning else {
            process.terminate()
            return .timeout
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data.prefix(4_096), as: UTF8.self).lowercased()
        if process.terminationStatus == 0 { return .launched }
        if message.contains("already loaded") || message.contains("service already exists") || message.contains("eexist") {
            return .alreadyExists
        }
        if message.contains("could not find service")
            || message.contains("no such process")
            || message.contains("esrch") {
            return .notFound
        }
        return .failed(exitCode: process.terminationStatus)
    }

    static func probeReadiness(
        endpoint: URL,
        bearerToken: String,
        timeout: TimeInterval
    ) -> Bool {
        guard endpoint == SharedOuroborosResolver.defaultEndpoint,
              SharedOuroborosBearerToken.isValid(bearerToken),
              timeout > 0, timeout <= 1 else { return false }
        let accepted = performReadinessProbe(
            endpoint: endpoint,
            bearerToken: bearerToken,
            timeout: timeout
        )
        guard accepted.isExactOuroboros else { return false }

        // A legacy unauthenticated service also accepts a syntactically valid
        // Authorization header. Prove enforcement with a different valid token
        // before granting managed steering trust.
        let rejected = performReadinessProbe(
            endpoint: endpoint,
            bearerToken: invalidatedToken(bearerToken),
            timeout: timeout
        )
        return rejected.isAuthenticationRejection
    }

    private static func invalidatedToken(_ token: String) -> String {
        let replacement = token.first == "a" ? "b" : "a"
        return replacement + token.dropFirst()
    }

    private static func performReadinessProbe(
        endpoint: URL,
        bearerToken: String,
        timeout: TimeInterval
    ) -> ReadinessResult {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(OuroborosMCPProtocolVersion.preferred, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "ourocode-readiness",
            "method": "initialize",
            "params": [
                "protocolVersion": OuroborosMCPProtocolVersion.preferred,
                "capabilities": [:],
                "clientInfo": ["name": "ourocode-readiness", "version": "0.1.0"],
            ],
        ])
        let semaphore = DispatchSemaphore(value: 0)
        let result = ReadinessResult()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            result.store(data: data, response: response)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        session.invalidateAndCancel()
        return result
    }

    private final class ReadinessResult: @unchecked Sendable {
        private let lock = NSLock()
        private var exact = false
        private var responseStatus: Int?

        func store(data: Data?, response: URLResponse?) {
            guard let http = response as? HTTPURLResponse else { return }
            lock.lock()
            responseStatus = http.statusCode
            lock.unlock()
            guard
                  (200 ..< 300).contains(http.statusCode),
                  let data,
                  data.count <= 1_048_576,
                  let object = Self.decodeMCPEnvelope(data),
                  let result = object["result"] as? [String: Any],
                  OuroborosMCPProtocolVersion.accepts(result["protocolVersion"] as? String),
                  let server = result["serverInfo"] as? [String: Any],
                  server["name"] as? String == "ouroboros-mcp",
                  server["version"] as? String == "0.51.6" else { return }
            lock.lock()
            exact = true
            lock.unlock()
        }

        private static func decodeMCPEnvelope(_ data: Data) -> [String: Any]? {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            // FastMCP 0.51.6 legitimately answers streamable HTTP initialize
            // with a one-event SSE envelope when the client accepts both
            // representations.
            guard let stream = String(data: data, encoding: .utf8) else { return nil }
            for line in stream.split(whereSeparator: { $0.isNewline }) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let payloadData = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    continue
                }
                return object
            }
            return nil
        }

        var isExactOuroboros: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exact
        }

        var isAuthenticationRejection: Bool {
            lock.lock()
            defer { lock.unlock() }
            return responseStatus == 401 || responseStatus == 403
        }
    }
}
