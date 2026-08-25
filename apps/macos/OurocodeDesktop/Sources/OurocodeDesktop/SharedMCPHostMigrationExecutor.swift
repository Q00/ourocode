import Darwin
import Foundation

/// The exact file and host-owned location of a supported MCP registration.
/// Callers must present a concrete path; this adapter never searches a home
/// directory and therefore cannot silently pick a similarly named config.
struct SharedMCPHostConfigTarget: Equatable {
    let registration: SharedMCPHostRegistration
    let configURL: URL
    /// Required only for Claude's local scope. It is the exact key already
    /// present below `projects` in the host-owned JSON document.
    let claudeProjectKey: String?
}

/// Maps only the host locations whose storage contract is implemented below.
/// The home/project URLs are explicit inputs so tests and callers never depend
/// on process-global HOME or the current working directory.
enum SharedMCPHostConfigLocator {
    static func supportedTarget(
        registration: SharedMCPHostRegistration,
        homeDirectory: URL,
        projectDirectory: URL? = nil
    ) -> Result<SharedMCPHostConfigTarget, SharedMCPHostMigrationExecutionFailure> {
        guard homeDirectory.isFileURL, homeDirectory.path.hasPrefix("/") else {
            return .failure(.invalidTargetPath)
        }
        let home = homeDirectory.standardizedFileURL
        switch registration {
        case .codex:
            return .success(.init(
                registration: .codex,
                configURL: home.appendingPathComponent(".codex/config.toml"),
                claudeProjectKey: nil
            ))
        case .claude(scope: .user):
            return .success(.init(
                registration: .claude(scope: .user),
                configURL: home.appendingPathComponent(".claude.json"),
                claudeProjectKey: nil
            ))
        case .claude(scope: .local):
            guard let projectDirectory,
                  projectDirectory.isFileURL,
                  projectDirectory.path.hasPrefix("/") else {
                return .failure(.registrationDoesNotMatchConfig)
            }
            return .success(.init(
                registration: .claude(scope: .local),
                configURL: home.appendingPathComponent(".claude.json"),
                claudeProjectKey: projectDirectory.standardizedFileURL.path
            ))
        case .claude(scope: .project):
            return .failure(.planner(.unsupportedClaudeScope(.project)))
        case .claudePlugin(let namespace):
            return .failure(.planner(.claudePluginCannotBeDisabledOrOverridden(namespace: namespace)))
        }
    }
}

struct SharedMCPHostMigrationDiff: Equatable {
    let registration: SharedMCPHostRegistration
    let configPath: String
    let entryPath: String
    let before: String
    let after: String
    let preservedSiblingServerCount: Int
}

struct SharedMCPHostMigrationPreview: Equatable {
    let planID: UUID
    let diff: SharedMCPHostMigrationDiff
}

/// This is intentionally an opaque handle. The backup path, original bytes,
/// and replacement bytes stay inside the executor so UI logging cannot leak a
/// host configuration or its environment variables.
struct SharedMCPHostRollbackToken: Equatable {
    let id: String
    let registration: SharedMCPHostRegistration
    let configPath: String

    fileprivate init(id: String, registration: SharedMCPHostRegistration, configPath: String) {
        self.id = id
        self.registration = registration
        self.configPath = configPath
    }
}

struct SharedMCPHostRollbackConfirmation: Equatable {
    let tokenID: String
    let phrase: String
}

enum SharedMCPHostMigrationExecutionFailure: Error, Equatable {
    case invalidTargetPath
    case targetMissingOrNotRegularFile
    case targetIsSymbolicLink
    case targetNotOwnedByCurrentUser
    case targetPermissionsNotOwnerOnly
    case targetHasMultipleHardLinks
    case configTooLarge
    case registrationMissing
    case unsupportedConfigShape
    case registrationDoesNotMatchConfig
    case planner(SharedMCPHostMigrationFailure)
    case previewNotFound
    case targetChangedAfterPreview
    case backupStorageUnsafe
    case backupWriteFailed
    case atomicWriteFailed
    case rollbackTokenUnknown
    case rollbackConfirmationMismatch
    case rollbackTargetChanged
    case rollbackBackupInvalid
    case tooManyLiveRollbackTokens
}

/// A synchronous, fail-closed adapter intended to sit behind an explicit UI
/// confirmation sheet. `preview` is read-only. The first filesystem mutation
/// is in `apply`, after the planner has validated the exact confirmation.
final class SharedMCPHostMigrationExecutor {
    static let rollbackConfirmationPhrase = "restore the previous Ouroboros MCP registration"

    private static let maximumConfigBytes = 1_048_576
    private static let maximumPendingPreviews = 16
    private static let maximumLiveRollbackTokens = 32
    private static let backupDirectoryName = ".ourocode-mcp-backups"

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let byteCount: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let permissions: mode_t
    }

    private struct SecureSnapshot {
        let data: Data
        let identity: FileIdentity
    }

    private struct DecodedConfig {
        let observation: SharedMCPServerObservation
        let replacement: Data
        let diff: SharedMCPHostMigrationDiff
    }

    private struct PendingMigration {
        let target: SharedMCPHostConfigTarget
        let original: SecureSnapshot
        let replacement: Data
        let plannerPreview: SharedMCPHostMigrationPlan
    }

    private struct RollbackAuthority {
        let token: SharedMCPHostRollbackToken
        let target: SharedMCPHostConfigTarget
        let backupURL: URL
        let originalData: Data
        let appliedData: Data
        let appliedIdentity: FileIdentity
        let permissions: mode_t
    }

    private let lock = NSLock()
    private let identifierGenerator: () -> String
    private var pending: [UUID: PendingMigration] = [:]
    private var pendingOrder: [UUID] = []
    private var rollbackAuthorities: [String: RollbackAuthority] = [:]

    init(identifierGenerator: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.identifierGenerator = identifierGenerator
    }

    func preview(
        target: SharedMCPHostConfigTarget,
        endpoint: SharedMCPEndpointAttestation
    ) -> Result<SharedMCPHostMigrationPreview, SharedMCPHostMigrationExecutionFailure> {
        lock.lock()
        defer { lock.unlock() }

        guard target.configURL.isFileURL,
              target.configURL.path.hasPrefix("/") else {
            return .failure(.invalidTargetPath)
        }
        let standardizedTarget = SharedMCPHostConfigTarget(
            registration: target.registration,
            configURL: target.configURL.standardizedFileURL,
            claudeProjectKey: target.claudeProjectKey
        )
        let snapshot: SecureSnapshot
        switch Self.readSecureSnapshot(at: standardizedTarget.configURL) {
        case .success(let value): snapshot = value
        case .failure(let failure): return .failure(failure)
        }
        guard snapshot.data.count <= Self.maximumConfigBytes else {
            return .failure(.configTooLarge)
        }

        let snapshotID = identifierGenerator()
        guard Self.isSafeIdentifier(snapshotID) else {
            return .failure(.backupStorageUnsafe)
        }
        let decoded: DecodedConfig
        switch Self.decode(
            snapshot.data,
            target: standardizedTarget,
            snapshotID: snapshotID,
            generation: Self.generation(for: snapshot.identity),
            endpoint: endpoint.endpoint
        ) {
        case .success(let value): decoded = value
        case .failure(let failure): return .failure(failure)
        }

        let plannerResult = SharedMCPHostMigrationPlanner.dryRun(
            observation: decoded.observation,
            endpoint: endpoint
        )
        let plannerPreview: SharedMCPHostMigrationPlan
        switch plannerResult {
        case .success(let value): plannerPreview = value
        case .failure(let failure): return .failure(.planner(failure))
        }

        if pendingOrder.count == Self.maximumPendingPreviews,
           let oldest = pendingOrder.first {
            pending.removeValue(forKey: oldest)
            pendingOrder.removeFirst()
        }
        pending[plannerPreview.planID] = PendingMigration(
            target: standardizedTarget,
            original: snapshot,
            replacement: decoded.replacement,
            plannerPreview: plannerPreview
        )
        pendingOrder.append(plannerPreview.planID)
        return .success(.init(planID: plannerPreview.planID, diff: decoded.diff))
    }

    func apply(
        previewID: UUID,
        confirmation: SharedMCPApplyConfirmation
    ) -> Result<SharedMCPHostRollbackToken, SharedMCPHostMigrationExecutionFailure> {
        lock.lock()
        defer { lock.unlock() }

        guard let migration = pending[previewID] else {
            return .failure(.previewNotFound)
        }
        guard rollbackAuthorities.count < Self.maximumLiveRollbackTokens else {
            return .failure(.tooManyLiveRollbackTokens)
        }
        switch SharedMCPHostMigrationPlanner.authorizeApply(
            migration.plannerPreview,
            confirmation: confirmation
        ) {
        case .failure(let failure): return .failure(.planner(failure))
        case .success: break
        }

        let current: SecureSnapshot
        switch Self.readSecureSnapshot(at: migration.target.configURL) {
        case .success(let value): current = value
        case .failure: return .failure(.targetChangedAfterPreview)
        }
        guard current.identity == migration.original.identity,
              current.data == migration.original.data else {
            return .failure(.targetChangedAfterPreview)
        }

        let tokenID = identifierGenerator()
        guard Self.isSafeIdentifier(tokenID), rollbackAuthorities[tokenID] == nil else {
            return .failure(.backupStorageUnsafe)
        }

        let backupURL: URL
        switch Self.writeBackup(
            migration.original.data,
            targetURL: migration.target.configURL,
            identifier: migration.plannerPreview.rollback.snapshotID
        ) {
        case .success(let value): backupURL = value
        case .failure(let failure): return .failure(failure)
        }

        switch Self.atomicReplace(
            at: migration.target.configURL,
            with: migration.replacement,
            permissions: migration.original.identity.permissions,
            identifier: migration.plannerPreview.rollback.snapshotID,
            expected: migration.original,
            conflictFailure: .targetChangedAfterPreview
        ) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        let applied: SecureSnapshot
        switch Self.readSecureSnapshot(at: migration.target.configURL) {
        case .success(let value): applied = value
        case .failure: return .failure(.atomicWriteFailed)
        }
        guard applied.data == migration.replacement,
              applied.identity.permissions == migration.original.identity.permissions else {
            return .failure(.atomicWriteFailed)
        }

        let token = SharedMCPHostRollbackToken(
            id: tokenID,
            registration: migration.target.registration,
            configPath: migration.target.configURL.path
        )
        rollbackAuthorities[tokenID] = RollbackAuthority(
            token: token,
            target: migration.target,
            backupURL: backupURL,
            originalData: migration.original.data,
            appliedData: migration.replacement,
            appliedIdentity: applied.identity,
            permissions: migration.original.identity.permissions
        )
        pending.removeValue(forKey: previewID)
        pendingOrder.removeAll { $0 == previewID }
        return .success(token)
    }

    func rollback(
        _ token: SharedMCPHostRollbackToken,
        confirmation: SharedMCPHostRollbackConfirmation
    ) -> Result<Void, SharedMCPHostMigrationExecutionFailure> {
        lock.lock()
        defer { lock.unlock() }

        guard confirmation.tokenID == token.id,
              confirmation.phrase == Self.rollbackConfirmationPhrase else {
            return .failure(.rollbackConfirmationMismatch)
        }
        guard let authority = rollbackAuthorities[token.id], authority.token == token else {
            return .failure(.rollbackTokenUnknown)
        }
        let current: SecureSnapshot
        switch Self.readSecureSnapshot(at: authority.target.configURL) {
        case .success(let value): current = value
        case .failure: return .failure(.rollbackTargetChanged)
        }
        guard current.identity == authority.appliedIdentity,
              current.data == authority.appliedData else {
            return .failure(.rollbackTargetChanged)
        }
        guard case .success(let backup) = Self.readSecureSnapshot(at: authority.backupURL),
              backup.data == authority.originalData,
              backup.identity.permissions == 0o600 else {
            return .failure(.rollbackBackupInvalid)
        }
        switch Self.atomicReplace(
            at: authority.target.configURL,
            with: authority.originalData,
            permissions: authority.permissions,
            identifier: token.id,
            expected: current,
            conflictFailure: .rollbackTargetChanged
        ) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        guard case .success(let restored) = Self.readSecureSnapshot(at: authority.target.configURL),
              restored.data == authority.originalData,
              restored.identity.permissions == authority.permissions else {
            return .failure(.atomicWriteFailed)
        }
        rollbackAuthorities.removeValue(forKey: token.id)
        // The exact original is durable again; remove only the executor-owned
        // 0600 backup. Failure to clean up does not make the rollback false.
        _ = unlink(authority.backupURL.path)
        Self.synchronizeDirectory(authority.backupURL.deletingLastPathComponent())
        return .success(())
    }

    private static func decode(
        _ data: Data,
        target: SharedMCPHostConfigTarget,
        snapshotID: String,
        generation: UInt64,
        endpoint: URL
    ) -> Result<DecodedConfig, SharedMCPHostMigrationExecutionFailure> {
        switch target.registration {
        case .codex:
            guard target.claudeProjectKey == nil else {
                return .failure(.registrationDoesNotMatchConfig)
            }
            return decodeCodex(
                data,
                target: target,
                snapshotID: snapshotID,
                generation: generation,
                endpoint: endpoint
            )
        case .claude(let scope):
            if scope == .project {
                return .failure(.planner(.unsupportedClaudeScope(.project)))
            }
            if (scope == .local) != (target.claudeProjectKey != nil) {
                return .failure(.registrationDoesNotMatchConfig)
            }
            return decodeClaude(
                data,
                target: target,
                snapshotID: snapshotID,
                generation: generation,
                endpoint: endpoint,
                scope: scope
            )
        case .claudePlugin(let namespace):
            return .failure(.planner(.claudePluginCannotBeDisabledOrOverridden(namespace: namespace)))
        }
    }

    private static func decodeCodex(
        _ data: Data,
        target: SharedMCPHostConfigTarget,
        snapshotID: String,
        generation: UInt64,
        endpoint: URL
    ) -> Result<DecodedConfig, SharedMCPHostMigrationExecutionFailure> {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            return .failure(.unsupportedConfigShape)
        }
        let pattern = #"(?m)^\[([^\]\n]+)\][ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .failure(.unsupportedConfigShape)
        }
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let headers = regex.matches(in: text, range: fullRange)
        let matching = headers.filter { match in
            guard let range = Range(match.range(at: 1), in: text) else { return false }
            return text[range] == "mcp_servers.ouroboros"
        }
        guard !matching.isEmpty else {
            return .failure(.registrationMissing)
        }
        guard matching.count == 1, let match = matching.first,
              let headerRange = Range(match.range, in: text) else {
            return .failure(.unsupportedConfigShape)
        }
        let nestedOuroborosHeaders = headers.filter { header in
            guard let range = Range(header.range(at: 1), in: text) else { return false }
            return text[range].hasPrefix("mcp_servers.ouroboros.")
        }
        guard nestedOuroborosHeaders.count <= 1,
              nestedOuroborosHeaders.allSatisfy({ header in
                  guard let range = Range(header.range(at: 1), in: text) else { return false }
                  return text[range] == "mcp_servers.ouroboros.env"
              }) else {
            return .failure(.unsupportedConfigShape)
        }
        let nextHeader = headers.first { $0.range.location > match.range.location }
        if !nestedOuroborosHeaders.isEmpty, nextHeader?.range.location != nestedOuroborosHeaders[0].range.location {
            // A nested entry table separated from its parent by another table
            // is too ambiguous for this intentionally small codec.
            return .failure(.unsupportedConfigShape)
        }
        let sectionEnd: String.Index
        if let nextHeader, let range = Range(nextHeader.range, in: text) {
            sectionEnd = range.lowerBound
        } else {
            sectionEnd = text.endIndex
        }
        let bodyStart = headerRange.upperBound
        let body = String(text[bodyStart ..< sectionEnd])
        var command: String?
        var arguments: [String]?
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("command") {
                guard command == nil,
                      let value = parseSingleLineAssignment(line, key: "command"),
                      let decoded = decodeJSONString(value) else {
                    return .failure(.unsupportedConfigShape)
                }
                command = decoded
            } else if line.hasPrefix("args") {
                guard arguments == nil,
                      let value = parseSingleLineAssignment(line, key: "args"),
                      let valueData = value.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String].self, from: valueData) else {
                    return .failure(.unsupportedConfigShape)
                }
                arguments = decoded
            } else {
                // Comments, environment tables, timeout fields, and unknown
                // semantics require a newer explicitly reviewed codec.
                return .failure(.unsupportedConfigShape)
            }
        }
        guard let command, let arguments else {
            return .failure(.unsupportedConfigShape)
        }
        var replacementEnd = sectionEnd
        if let environmentHeader = nestedOuroborosHeaders.first,
           let environmentHeaderRange = Range(environmentHeader.range, in: text) {
            let followingHeader = headers.first { $0.range.location > environmentHeader.range.location }
            let environmentEnd: String.Index
            if let followingHeader, let range = Range(followingHeader.range, in: text) {
                environmentEnd = range.lowerBound
            } else {
                environmentEnd = text.endIndex
            }
            let environmentBody = text[environmentHeaderRange.upperBound ..< environmentEnd]
            var environmentKeys = Set<String>()
            for rawLine in environmentBody.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") || line.hasPrefix(";") { continue }
                guard let equals = line.firstIndex(of: "=") else {
                    return .failure(.unsupportedConfigShape)
                }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                      environmentKeys.insert(String(key)).inserted,
                      decodeJSONString(String(value)) != nil else {
                    return .failure(.unsupportedConfigShape)
                }
            }
            replacementEnd = environmentEnd
        }
        let replacementSection = "[mcp_servers.ouroboros]\nurl = \"\(endpoint.absoluteString)\"\n\n"
        var replacementText = text
        replacementText.replaceSubrange(headerRange.lowerBound ..< replacementEnd, with: replacementSection)
        guard let replacement = replacementText.data(using: .utf8) else {
            return .failure(.unsupportedConfigShape)
        }
        let observation = SharedMCPServerObservation(
            registration: .codex,
            serverName: "ouroboros",
            transport: .stdio(executable: command, arguments: arguments),
            rollback: .init(snapshotID: snapshotID, configGeneration: generation)
        )
        return .success(.init(
            observation: observation,
            replacement: replacement,
            diff: .init(
                registration: .codex,
                configPath: target.configURL.path,
                entryPath: "mcp_servers.ouroboros",
                before: "stdio via \(URL(fileURLWithPath: command).lastPathComponent)",
                after: endpoint.absoluteString,
                preservedSiblingServerCount: max(0, headers.filter { header in
                    guard let range = Range(header.range(at: 1), in: text) else { return false }
                    let name = text[range]
                    return name.hasPrefix("mcp_servers.")
                        && name.dropFirst("mcp_servers.".count).contains(".") == false
                }.count - 1)
            )
        ))
    }

    private static func decodeClaude(
        _ data: Data,
        target: SharedMCPHostConfigTarget,
        snapshotID: String,
        generation: UInt64,
        endpoint: URL,
        scope: SharedMCPClaudeScope
    ) -> Result<DecodedConfig, SharedMCPHostMigrationExecutionFailure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unsupportedConfigShape)
        }
        var updated = root
        let servers: [String: Any]
        let entryPath: String
        if scope == .user {
            guard let value = root["mcpServers"] as? [String: Any] else {
                return .failure(.unsupportedConfigShape)
            }
            servers = value
            entryPath = "mcpServers.ouroboros"
        } else {
            guard let projectKey = target.claudeProjectKey,
                  var projects = root["projects"] as? [String: Any],
                  var project = projects[projectKey] as? [String: Any],
                  let value = project["mcpServers"] as? [String: Any] else {
                return .failure(.unsupportedConfigShape)
            }
            servers = value
            var migratedServers = value
            migratedServers["ouroboros"] = ["type": "http", "url": endpoint.absoluteString]
            project["mcpServers"] = migratedServers
            projects[projectKey] = project
            updated["projects"] = projects
            entryPath = "projects[project].mcpServers.ouroboros"
        }
        guard servers["ouroboros"] != nil else {
            return .failure(.registrationMissing)
        }
        guard let entry = servers["ouroboros"] as? [String: Any],
              Set(entry.keys).isSubset(of: ["type", "command", "args", "env"]),
              (entry["type"] == nil || (entry["type"] as? String) == "stdio"),
              let command = entry["command"] as? String,
              let arguments = entry["args"] as? [String] else {
            return .failure(.unsupportedConfigShape)
        }
        if let environment = entry["env"] {
            guard let values = environment as? [String: Any],
                  values.values.allSatisfy({ $0 is String }) else {
                return .failure(.unsupportedConfigShape)
            }
        }
        if scope == .user {
            var migratedServers = servers
            migratedServers["ouroboros"] = ["type": "http", "url": endpoint.absoluteString]
            updated["mcpServers"] = migratedServers
        }
        guard JSONSerialization.isValidJSONObject(updated),
              var replacement = try? JSONSerialization.data(
                  withJSONObject: updated,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return .failure(.unsupportedConfigShape)
        }
        replacement.append(0x0A)
        let observation = SharedMCPServerObservation(
            registration: .claude(scope: scope),
            serverName: "ouroboros",
            transport: .stdio(executable: command, arguments: arguments),
            rollback: .init(snapshotID: snapshotID, configGeneration: generation)
        )
        return .success(.init(
            observation: observation,
            replacement: replacement,
            diff: .init(
                registration: .claude(scope: scope),
                configPath: target.configURL.path,
                entryPath: entryPath,
                before: "stdio via \(URL(fileURLWithPath: command).lastPathComponent)",
                after: endpoint.absoluteString,
                preservedSiblingServerCount: max(0, servers.count - 1)
            )
        ))
    }

    private static func parseSingleLineAssignment(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let suffix = line.dropFirst(key.count)
        guard let equals = suffix.firstIndex(of: "="),
              suffix[..<equals].allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let value = suffix[suffix.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func decodeJSONString(_ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func generation(for identity: FileIdentity) -> UInt64 {
        var value = UInt64(bitPattern: Int64(identity.modifiedSeconds))
        value ^= UInt64(identity.inode) &* 1_099_511_628_211
        value ^= UInt64(identity.byteCount)
        return max(1, value)
    }

    private static func readSecureSnapshot(
        at url: URL
    ) -> Result<SecureSnapshot, SharedMCPHostMigrationExecutionFailure> {
        let path = url.path
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else {
            return .failure(.targetMissingOrNotRegularFile)
        }
        if (linkInfo.st_mode & S_IFMT) == S_IFLNK {
            return .failure(.targetIsSymbolicLink)
        }
        guard (linkInfo.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.targetMissingOrNotRegularFile)
        }
        guard linkInfo.st_uid == geteuid() else {
            return .failure(.targetNotOwnedByCurrentUser)
        }
        guard (linkInfo.st_mode & 0o077) == 0 else {
            return .failure(.targetPermissionsNotOwnerOnly)
        }
        guard linkInfo.st_nlink == 1 else {
            return .failure(.targetHasMultipleHardLinks)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return .failure(.targetMissingOrNotRegularFile)
        }
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_dev == linkInfo.st_dev,
              openedInfo.st_ino == linkInfo.st_ino else {
            return .failure(.targetMissingOrNotRegularFile)
        }
        guard openedInfo.st_size >= 0,
              openedInfo.st_size <= off_t(maximumConfigBytes + 1) else {
            return .failure(.configTooLarge)
        }
        var data = Data()
        data.reserveCapacity(Int(openedInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.targetMissingOrNotRegularFile)
            }
            data.append(buffer, count: count)
            if data.count > maximumConfigBytes {
                return .failure(.configTooLarge)
            }
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_size == openedInfo.st_size,
              finalInfo.st_mtimespec.tv_sec == openedInfo.st_mtimespec.tv_sec,
              finalInfo.st_mtimespec.tv_nsec == openedInfo.st_mtimespec.tv_nsec else {
            return .failure(.targetMissingOrNotRegularFile)
        }
        return .success(.init(data: data, identity: identity(from: finalInfo)))
    }

    private static func identity(from info: stat) -> FileIdentity {
        .init(
            device: info.st_dev,
            inode: info.st_ino,
            byteCount: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            permissions: info.st_mode & 0o777
        )
    }

    private static func writeBackup(
        _ data: Data,
        targetURL: URL,
        identifier: String
    ) -> Result<URL, SharedMCPHostMigrationExecutionFailure> {
        let directory = targetURL.deletingLastPathComponent()
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            return .failure(.backupStorageUnsafe)
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & 0o077) == 0 else {
            return .failure(.backupStorageUnsafe)
        }
        let backupURL = directory.appendingPathComponent("\(identifier).backup", isDirectory: false)
        let result = writeExclusiveFile(data, at: backupURL, permissions: 0o600)
        guard result else { return .failure(.backupWriteFailed) }
        synchronizeDirectory(directory)
        return .success(backupURL)
    }

    private static func atomicReplace(
        at targetURL: URL,
        with data: Data,
        permissions: mode_t,
        identifier: String,
        expected: SecureSnapshot,
        conflictFailure: SharedMCPHostMigrationExecutionFailure
    ) -> Result<Void, SharedMCPHostMigrationExecutionFailure> {
        let directory = targetURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".ourocode-migrate-\(identifier).tmp")
        guard writeExclusiveFile(data, at: temporaryURL, permissions: permissions) else {
            return .failure(.atomicWriteFailed)
        }
        // RENAME_SWAP makes the replacement and capture of the prior inode one
        // indivisible operation. Inspecting the displaced inode closes the
        // check/rename race with another host process editing its config.
        guard renamex_np(temporaryURL.path, targetURL.path, UInt32(RENAME_SWAP)) == 0 else {
            _ = unlink(temporaryURL.path)
            return .failure(.atomicWriteFailed)
        }
        let displaced = readSecureSnapshot(at: temporaryURL)
        guard case .success(let previous) = displaced,
              previous.identity == expected.identity,
              previous.data == expected.data else {
            // The target changed between the caller's last check and the
            // atomic swap. Put that exact inode back; never overwrite it.
            if renamex_np(temporaryURL.path, targetURL.path, UInt32(RENAME_SWAP)) != 0 {
                return .failure(.atomicWriteFailed)
            }
            _ = unlink(temporaryURL.path)
            return .failure(conflictFailure)
        }
        _ = unlink(temporaryURL.path)
        synchronizeDirectory(directory)
        return .success(())
    }

    private static func synchronizeDirectory(_ directory: URL) {
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private static func writeExclusiveFile(_ data: Data, at url: URL, permissions: mode_t) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        guard descriptor >= 0 else { return false }
        var succeeded = fchmod(descriptor, permissions) == 0
        if succeeded {
            succeeded = data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    written += count
                }
                return true
            }
        }
        if succeeded { succeeded = fsync(descriptor) == 0 }
        if close(descriptor) != 0 { succeeded = false }
        if !succeeded { _ = unlink(url.path) }
        return succeeded
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}
