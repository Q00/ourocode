import Foundation

/// A deliberately secret-free projection of one host MCP registration.
///
/// Discovery code must build this value from the named server entry only. It
/// cannot pass environment variables, HTTP headers, bearer tokens, or the raw
/// host configuration to the planner because those fields do not exist here.
enum SharedMCPObservedTransport: Equatable {
    case stdio(executable: String, arguments: [String])
    case streamableHTTP
    case other
}

enum SharedMCPClaudeScope: String, Codable, Equatable {
    case user
    case local
    case project
}

enum SharedMCPHostRegistration: Equatable {
    case codex
    case claude(scope: SharedMCPClaudeScope)
    /// Claude plugin MCP servers are controlled by the plugin lifecycle and
    /// are not equivalent to user/local registrations with a funny name.
    case claudePlugin(namespace: String)
}

/// Points at an exact, host-owned rollback snapshot without exposing it to the
/// planner. The snapshot owner is responsible for restoring the full entry,
/// including any secret fields the planner never reads.
struct SharedMCPRollbackMetadata: Equatable {
    let snapshotID: String
    let configGeneration: UInt64

    fileprivate var isValid: Bool {
        guard (1 ... 128).contains(snapshotID.utf8.count), configGeneration > 0 else {
            return false
        }
        return snapshotID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }
}

struct SharedMCPServerObservation: Equatable {
    let registration: SharedMCPHostRegistration
    let serverName: String
    let transport: SharedMCPObservedTransport
    let rollback: SharedMCPRollbackMetadata?
}

/// Evidence supplied by the shared-service supervisor after it has matched its
/// owner-only artifacts and completed an MCP readiness probe. A URL by itself
/// is never considered verified.
struct SharedMCPEndpointAttestation: Equatable {
    let endpoint: URL
    let supervisorLabel: String
    let contractSchemaVersion: Int
    let serviceVersion: OuroborosServiceVersion
    let ownershipArtifactsVerified: Bool
    let readinessProbeSucceeded: Bool
}

struct SharedMCPHostCommand: Equatable {
    /// argv, not a shell string. Future apply code must use Process directly.
    let arguments: [String]
}

enum SharedMCPMigrationMode: Equatable {
    case dryRun
    case explicitApplyAuthorized
}

struct SharedMCPHostMigrationPlan: Equatable {
    let planID: UUID
    let mode: SharedMCPMigrationMode
    let registration: SharedMCPHostRegistration
    let serverName: String
    let endpoint: URL
    let commands: [SharedMCPHostCommand]
    let rollback: SharedMCPRollbackMetadata
}

struct SharedMCPApplyConfirmation: Equatable {
    let planID: UUID
    let phrase: String
}

enum SharedMCPHostMigrationFailure: Error, Equatable {
    case endpointNotLoopback
    case endpointUnverified
    case invalidServerName
    case notStdio
    case notOuroboros
    case missingOrInvalidRollbackMetadata
    case unsupportedClaudeScope(SharedMCPClaudeScope)
    case claudePluginCannotBeDisabledOrOverridden(namespace: String)
    case applyConfirmationMismatch
}

/// Pure host migration policy. This type has no filesystem, subprocess,
/// launchd, or process-management API. In particular, authorizing a plan does
/// not execute it; execution belongs to a later, separately reviewed adapter.
enum SharedMCPHostMigrationPlanner {
    static let applyConfirmationPhrase = "migrate Ouroboros to the shared MCP service"

    static func dryRun(
        observation: SharedMCPServerObservation,
        endpoint: SharedMCPEndpointAttestation
    ) -> Result<SharedMCPHostMigrationPlan, SharedMCPHostMigrationFailure> {
        if !isStrictLoopbackMCPURL(endpoint.endpoint) {
            return .failure(.endpointNotLoopback)
        }
        guard endpoint.supervisorLabel == SharedOuroborosResolver.sharedLaunchdLabel,
              endpoint.contractSchemaVersion == 5,
              endpoint.serviceVersion == SharedOuroborosResolver.requiredVersion,
              endpoint.endpoint == SharedOuroborosResolver.defaultEndpoint,
              endpoint.ownershipArtifactsVerified,
              endpoint.readinessProbeSucceeded else {
            return .failure(.endpointUnverified)
        }
        guard isSafeServerName(observation.serverName) else {
            return .failure(.invalidServerName)
        }
        guard let rollback = observation.rollback, rollback.isValid else {
            return .failure(.missingOrInvalidRollbackMetadata)
        }
        guard case .stdio(let executable, let arguments) = observation.transport else {
            return .failure(.notStdio)
        }
        guard isOuroborosStdio(executable: executable, arguments: arguments) else {
            return .failure(.notOuroboros)
        }

        let commands: [SharedMCPHostCommand]
        switch observation.registration {
        case .codex:
            guard observation.serverName == "ouroboros" else {
                return .failure(.invalidServerName)
            }
            commands = [
                .init(arguments: ["codex", "mcp", "remove", "ouroboros"]),
                .init(arguments: [
                    "codex", "mcp", "add", "ouroboros", "--url",
                    endpoint.endpoint.absoluteString,
                ]),
            ]
        case .claude(let scope):
            guard observation.serverName == "ouroboros" else {
                return .failure(.invalidServerName)
            }
            guard scope == .user || scope == .local else {
                return .failure(.unsupportedClaudeScope(scope))
            }
            commands = [
                .init(arguments: [
                    "claude", "mcp", "remove", "ouroboros", "--scope", scope.rawValue,
                ]),
                .init(arguments: [
                    "claude", "mcp", "add", "--transport", "http", "--scope",
                    scope.rawValue, "ouroboros", endpoint.endpoint.absoluteString,
                ]),
            ]
        case .claudePlugin(let namespace):
            guard isSafeServerName(namespace) else {
                return .failure(.invalidServerName)
            }
            // Claude currently provides no verified host command that lets
            // Ourocode disable or override one namespaced MCP server while
            // preserving the rest of the plugin. Claiming migration would
            // leave the plugin stdio child active alongside the shared URL.
            return .failure(.claudePluginCannotBeDisabledOrOverridden(namespace: namespace))
        }

        return .success(.init(
            planID: UUID(),
            mode: .dryRun,
            registration: observation.registration,
            serverName: observation.serverName,
            endpoint: endpoint.endpoint,
            commands: commands,
            rollback: rollback
        ))
    }

    /// Converts a reviewed preview into an apply-authorized value. It still
    /// performs no mutation and returns no shell command string.
    static func authorizeApply(
        _ preview: SharedMCPHostMigrationPlan,
        confirmation: SharedMCPApplyConfirmation
    ) -> Result<SharedMCPHostMigrationPlan, SharedMCPHostMigrationFailure> {
        guard preview.mode == .dryRun,
              confirmation.planID == preview.planID,
              confirmation.phrase == applyConfirmationPhrase else {
            return .failure(.applyConfirmationMismatch)
        }
        return .success(.init(
            planID: preview.planID,
            mode: .explicitApplyAuthorized,
            registration: preview.registration,
            serverName: preview.serverName,
            endpoint: preview.endpoint,
            commands: preview.commands,
            rollback: preview.rollback
        ))
    }

    private static func isStrictLoopbackMCPURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "::1",
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/mcp" else { return false }
        return true
    }

    private static func isSafeServerName(_ name: String) -> Bool {
        guard (1 ... 128).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._:@/-".unicodeScalars.contains($0)
        }
    }

    private static func isOuroborosStdio(executable: String, arguments: [String]) -> Bool {
        guard !executable.isEmpty, executable.utf8.count <= 4_096,
              arguments.count <= 128,
              arguments.allSatisfy({ $0.utf8.count <= 4_096 }) else { return false }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let lowered = arguments.map { $0.lowercased() }

        if executableName == "ouroboros" {
            return containsContiguous(lowered, ["mcp", "serve"])
        }
        if executableName == "uvx" || executableName == "uv" {
            let pinsOuroboros = lowered.contains { argument in
                argument.hasPrefix("ouroboros-ai") || argument.hasPrefix("ouroboros[")
            }
            return pinsOuroboros && containsContiguous(lowered, ["ouroboros", "mcp", "serve"])
        }
        if executableName.hasPrefix("python") {
            return containsContiguous(lowered, ["-m", "ouroboros", "mcp", "serve"])
        }
        return false
    }

    private static func containsContiguous(_ values: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, values.count >= needle.count else { return false }
        return (0 ... values.count - needle.count).contains { index in
            Array(values[index ..< index + needle.count]) == needle
        }
    }
}
