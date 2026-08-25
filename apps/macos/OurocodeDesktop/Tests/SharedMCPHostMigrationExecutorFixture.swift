import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class DeterministicIdentifiers {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        guard !values.isEmpty else { return "fixture-exhausted" }
        return values.removeFirst()
    }
}

@main
private enum SharedMCPHostMigrationExecutorFixture {
    static func main() throws {
        supportedLocationsAreExact()
        try codexPreviewApplyAndRollbackAreExact()
        try codexNestedEnvironmentTableIsMigratedAndRestoredExactly()
        try weakConfirmationCannotMutate()
        try changedTargetFailsBeforeBackup()
        try unsafeTargetsFailClosed()
        try claudeUserMigrationPreservesSiblingsAndHidesSecrets()
        try claudeLocalUsesExactProjectKey()
        try missingRegistrationsAreDistinguishedFromUnsupportedShapes()
        try unsupportedShapesFailClosed()
        try rollbackCannotClobberLaterEdits()
        try liveCodexPreviewIsReadOnlyWhenRequested()
        print("PASS: exact shared-host config detection, secret-free preview, atomic apply, and guarded rollback")
    }

    private static func supportedLocationsAreExact() {
        let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)
        let project = URL(fileURLWithPath: "/fixture/project", isDirectory: true)
        let codex = SharedMCPHostConfigLocator.supportedTarget(
            registration: .codex,
            homeDirectory: home
        )
        guard case .success(let codexTarget) = codex else {
            return require(false, "Codex config location was not detected")
        }
        require(codexTarget.configURL.path == "/fixture/home/.codex/config.toml", "Codex config path drifted")
        let user = SharedMCPHostConfigLocator.supportedTarget(
            registration: .claude(scope: .user),
            homeDirectory: home
        )
        guard case .success(let userTarget) = user else {
            return require(false, "Claude user config location was not detected")
        }
        require(userTarget.configURL.path == "/fixture/home/.claude.json", "Claude user path drifted")
        let local = SharedMCPHostConfigLocator.supportedTarget(
            registration: .claude(scope: .local),
            homeDirectory: home,
            projectDirectory: project
        )
        guard case .success(let localTarget) = local else {
            return require(false, "Claude local config location was not detected")
        }
        require(localTarget.configURL == userTarget.configURL, "Claude local did not use the host-owned document")
        require(localTarget.claudeProjectKey == "/fixture/project", "Claude local project key drifted")
        require(
            SharedMCPHostConfigLocator.supportedTarget(
                registration: .claude(scope: .local),
                homeDirectory: home
            ) == .failure(.registrationDoesNotMatchConfig),
            "Claude local location was guessed without a project"
        )
        require(
            SharedMCPHostConfigLocator.supportedTarget(
                registration: .claude(scope: .project),
                homeDirectory: home,
                projectDirectory: project
            ) == .failure(.planner(.unsupportedClaudeScope(.project))),
            "unsupported Claude project file was targeted"
        )
    }

    private static func attestation() -> SharedMCPEndpointAttestation {
        .init(
            endpoint: SharedOuroborosResolver.defaultEndpoint,
            supervisorLabel: SharedOuroborosResolver.sharedLaunchdLabel,
            contractSchemaVersion: 5,
            serviceVersion: SharedOuroborosResolver.requiredVersion,
            ownershipArtifactsVerified: true,
            readinessProbeSucceeded: true
        )
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private static func withTemporaryConfig(
        fixture name: String,
        body: (URL, Data) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-migration-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: fixtureURL(name))
        let target = root.appendingPathComponent(name)
        try original.write(to: target)
        require(chmod(target.path, 0o600) == 0, "fixture chmod failed")
        try body(target, original)
    }

    private static func makeExecutor(_ prefix: String) -> SharedMCPHostMigrationExecutor {
        let identifiers = DeterministicIdentifiers(["\(prefix)-snapshot", "\(prefix)-rollback"])
        return SharedMCPHostMigrationExecutor(identifierGenerator: identifiers.next)
    }

    private static func codexTarget(_ url: URL) -> SharedMCPHostConfigTarget {
        .init(registration: .codex, configURL: url, claudeProjectKey: nil)
    }

    private static func preview(
        executor: SharedMCPHostMigrationExecutor,
        target: SharedMCPHostConfigTarget
    ) -> SharedMCPHostMigrationPreview {
        switch executor.preview(target: target, endpoint: attestation()) {
        case .success(let value): return value
        case .failure(let error):
            require(false, "preview failed: \(error)")
            fatalError("unreachable")
        }
    }

    private static func apply(
        executor: SharedMCPHostMigrationExecutor,
        preview: SharedMCPHostMigrationPreview
    ) -> SharedMCPHostRollbackToken {
        let confirmation = SharedMCPApplyConfirmation(
            planID: preview.planID,
            phrase: SharedMCPHostMigrationPlanner.applyConfirmationPhrase
        )
        switch executor.apply(previewID: preview.planID, confirmation: confirmation) {
        case .success(let value): return value
        case .failure(let error):
            require(false, "apply failed: \(error)")
            fatalError("unreachable")
        }
    }

    private static func rollback(
        executor: SharedMCPHostMigrationExecutor,
        token: SharedMCPHostRollbackToken
    ) {
        let confirmation = SharedMCPHostRollbackConfirmation(
            tokenID: token.id,
            phrase: SharedMCPHostMigrationExecutor.rollbackConfirmationPhrase
        )
        if case .failure(let error) = executor.rollback(token, confirmation: confirmation) {
            require(false, "rollback failed: \(error)")
        }
    }

    private static func codexPreviewApplyAndRollbackAreExact() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, original in
            let executor = makeExecutor("codex")
            let migration = preview(executor: executor, target: codexTarget(url))
            let afterPreview = try Data(contentsOf: url)
            require(afterPreview == original, "preview mutated Codex config")
            require(migration.diff.entryPath == "mcp_servers.ouroboros", "Codex diff path changed")
            require(migration.diff.before == "stdio via uvx", "Codex preview included unexpected argv")
            require(migration.diff.preservedSiblingServerCount == 1, "Codex sibling count changed")
            require(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".ourocode-mcp-backups").path), "preview created backup storage")

            let token = apply(executor: executor, preview: migration)
            let migrated = try String(contentsOf: url, encoding: .utf8)
            require(migrated.contains("[mcp_servers.ouroboros]\nurl = \"http://127.0.0.1:8976/mcp\""), "Codex URL entry was not written")
            require(migrated.contains("[mcp_servers.notes]"), "Codex sibling was lost")
            require(!migrated.contains("ouroboros-ai=="), "Codex stdio entry survived migration")
            require(filePermissions(url) == 0o600, "Codex permissions were not preserved")

            let weakRollback = executor.rollback(
                token,
                confirmation: .init(tokenID: token.id, phrase: "undo")
            )
            guard case .failure(.rollbackConfirmationMismatch) = weakRollback else {
                return require(false, "weak rollback confirmation was accepted")
            }
            let afterWeakRollback = try String(contentsOf: url, encoding: .utf8)
            require(afterWeakRollback == migrated, "weak rollback confirmation mutated config")

            rollback(executor: executor, token: token)
            let afterRollback = try Data(contentsOf: url)
            require(afterRollback == original, "Codex rollback was not byte-exact")
            require(filePermissions(url) == 0o600, "Codex rollback permissions changed")
        }
    }

    private static func weakConfirmationCannotMutate() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, original in
            let executor = makeExecutor("confirmation")
            let migration = preview(executor: executor, target: codexTarget(url))
            let result = executor.apply(
                previewID: migration.planID,
                confirmation: .init(planID: migration.planID, phrase: "yes")
            )
            require(result == .failure(.planner(.applyConfirmationMismatch)), "weak confirmation was accepted")
            let afterFailedConfirmation = try Data(contentsOf: url)
            require(afterFailedConfirmation == original, "failed confirmation mutated config")
            require(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".ourocode-mcp-backups").path), "failed confirmation created backup storage")
        }
    }

    private static func codexNestedEnvironmentTableIsMigratedAndRestoredExactly() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, original in
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(
                of: "\n[profiles.default]",
                with: "\n[mcp_servers.ouroboros.env]\nOUROBOROS_AGENT_RUNTIME = \"codex\"\nOUROBOROS_LLM_BACKEND = \"private\"\n\n[profiles.default]"
            )
            text = text.replacingOccurrences(
                of: "[mcp_servers.ouroboros.env]\n",
                with: "[mcp_servers.ouroboros.env]\n# Values stay secret and comments must remain structurally harmless.\n"
            )
            try Data(text.utf8).write(to: url)
            require(chmod(url.path, 0o600) == 0, "nested environment fixture chmod failed")

            let executor = makeExecutor("codex-environment")
            let migration = preview(executor: executor, target: codexTarget(url))
            require(migration.diff.preservedSiblingServerCount == 1, "nested environment counted as a sibling server")
            require(!String(describing: migration).contains("private"), "Codex preview leaked an environment value")
            let token = apply(executor: executor, preview: migration)
            let migrated = try String(contentsOf: url, encoding: .utf8)
            require(!migrated.contains("mcp_servers.ouroboros.env"), "obsolete stdio environment table survived migration")
            require(!migrated.contains("OUROBOROS_LLM_BACKEND"), "obsolete stdio environment value survived migration")
            require(migrated.contains("[mcp_servers.notes]"), "Codex sibling was lost after nested environment migration")

            rollback(executor: executor, token: token)
            let restored = try Data(contentsOf: url)
            require(restored == Data(text.utf8), "nested environment rollback was not byte-exact")
            require(original != Data(text.utf8), "nested environment fixture did not change")
        }
    }

    private static func changedTargetFailsBeforeBackup() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            let executor = makeExecutor("stale")
            let migration = preview(executor: executor, target: codexTarget(url))
            try Data("# changed after preview\n".utf8).write(to: url)
            require(chmod(url.path, 0o600) == 0, "stale fixture chmod failed")
            let result = executor.apply(
                previewID: migration.planID,
                confirmation: .init(
                    planID: migration.planID,
                    phrase: SharedMCPHostMigrationPlanner.applyConfirmationPhrase
                )
            )
            require(result == .failure(.targetChangedAfterPreview), "stale preview overwrote later edit")
            require(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".ourocode-mcp-backups").path), "stale apply created backup")
        }
    }

    private static func unsafeTargetsFailClosed() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            require(chmod(url.path, 0o644) == 0, "unsafe fixture chmod failed")
            let result = makeExecutor("mode").preview(target: codexTarget(url), endpoint: attestation())
            require(result == .failure(.targetPermissionsNotOwnerOnly), "group/world-readable config was accepted")
        }
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            let link = url.deletingLastPathComponent().appendingPathComponent("linked.toml")
            require(symlink(url.path, link.path) == 0, "symlink fixture failed")
            let result = makeExecutor("link").preview(target: codexTarget(link), endpoint: attestation())
            require(result == .failure(.targetIsSymbolicLink), "symlink config was accepted")
        }
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            let linked = url.deletingLastPathComponent().appendingPathComponent("hardlink.toml")
            require(link(url.path, linked.path) == 0, "hard-link fixture failed")
            let result = makeExecutor("hardlink").preview(target: codexTarget(url), endpoint: attestation())
            require(result == .failure(.targetHasMultipleHardLinks), "multiply-linked config was accepted")
        }
    }

    private static func claudeUserMigrationPreservesSiblingsAndHidesSecrets() throws {
        try withTemporaryConfig(fixture: "shared-mcp-claude-user-config.json") { url, original in
            let executor = makeExecutor("claude-user")
            let target = SharedMCPHostConfigTarget(
                registration: .claude(scope: .user),
                configURL: url,
                claudeProjectKey: nil
            )
            let migration = preview(executor: executor, target: target)
            require(!String(describing: migration).contains("DO_NOT_LEAK"), "Claude preview leaked environment value")
            require(migration.diff.preservedSiblingServerCount == 1, "Claude sibling count changed")
            let token = apply(executor: executor, preview: migration)
            let root = try json(at: url)
            let servers = root["mcpServers"] as? [String: Any]
            let ouroboros = servers?["ouroboros"] as? [String: Any]
            require(ouroboros?["type"] as? String == "http", "Claude user transport was not migrated")
            require(ouroboros?["url"] as? String == "http://127.0.0.1:8976/mcp", "Claude user URL changed")
            require(servers?["notes"] != nil && root["theme"] as? String == "dark", "Claude user siblings were lost")
            rollback(executor: executor, token: token)
            let afterRollback = try Data(contentsOf: url)
            require(afterRollback == original, "Claude user rollback was not byte-exact")
        }
    }

    private static func claudeLocalUsesExactProjectKey() throws {
        try withTemporaryConfig(fixture: "shared-mcp-claude-local-config.json") { url, _ in
            let missingKeyTarget = SharedMCPHostConfigTarget(
                registration: .claude(scope: .local),
                configURL: url,
                claudeProjectKey: nil
            )
            require(
                makeExecutor("local-missing").preview(target: missingKeyTarget, endpoint: attestation()) == .failure(.registrationDoesNotMatchConfig),
                "Claude local scope was accepted without exact project key"
            )
            let executor = makeExecutor("claude-local")
            let target = SharedMCPHostConfigTarget(
                registration: .claude(scope: .local),
                configURL: url,
                claudeProjectKey: "/fixture/project"
            )
            let migration = preview(executor: executor, target: target)
            require(migration.diff.entryPath == "projects[project].mcpServers.ouroboros", "Claude local diff exposed project path")
            _ = apply(executor: executor, preview: migration)
            let root = try json(at: url)
            let projects = root["projects"] as? [String: Any]
            let project = projects?["/fixture/project"] as? [String: Any]
            let servers = project?["mcpServers"] as? [String: Any]
            let ouroboros = servers?["ouroboros"] as? [String: Any]
            require(ouroboros?["type"] as? String == "http", "Claude local entry was not migrated")
            require(project?["trusted"] as? Bool == true, "Claude local project metadata was lost")
            require(projects?["/fixture/other"] != nil, "unrelated Claude project was lost")
        }
    }

    private static func unsupportedShapesFailClosed() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "args = [", with: "env = { SECRET = \"x\" }\nargs = [")
            try Data(text.utf8).write(to: url)
            require(chmod(url.path, 0o600) == 0, "unsupported Codex chmod failed")
            require(
                makeExecutor("unknown-toml").preview(target: codexTarget(url), endpoint: attestation()) == .failure(.unsupportedConfigShape),
                "unknown Codex entry semantics were discarded"
            )
        }
        try withTemporaryConfig(fixture: "shared-mcp-claude-user-config.json") { url, _ in
            var root = try json(at: url)
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            var ouroboros = servers["ouroboros"] as? [String: Any] ?? [:]
            ouroboros["unknown"] = true
            servers["ouroboros"] = ouroboros
            root["mcpServers"] = servers
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            require(chmod(url.path, 0o600) == 0, "unsupported Claude chmod failed")
            let target = SharedMCPHostConfigTarget(
                registration: .claude(scope: .user),
                configURL: url,
                claudeProjectKey: nil
            )
            require(
                makeExecutor("unknown-json").preview(target: target, endpoint: attestation()) == .failure(.unsupportedConfigShape),
                "unknown Claude entry semantics were discarded"
            )
        }
    }

    private static func missingRegistrationsAreDistinguishedFromUnsupportedShapes() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "mcp_servers.ouroboros", with: "mcp_servers.other")
            try Data(text.utf8).write(to: url)
            require(chmod(url.path, 0o600) == 0, "missing Codex fixture chmod failed")
            require(
                makeExecutor("missing-codex").preview(target: codexTarget(url), endpoint: attestation()) == .failure(.registrationMissing),
                "missing Codex registration was reported as an unsafe shape"
            )
        }
        try withTemporaryConfig(fixture: "shared-mcp-claude-user-config.json") { url, _ in
            var root = try json(at: url)
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: "ouroboros")
            root["mcpServers"] = servers
            try JSONSerialization.data(withJSONObject: root).write(to: url)
            require(chmod(url.path, 0o600) == 0, "missing Claude fixture chmod failed")
            let target = SharedMCPHostConfigTarget(
                registration: .claude(scope: .user),
                configURL: url,
                claudeProjectKey: nil
            )
            require(
                makeExecutor("missing-claude").preview(target: target, endpoint: attestation()) == .failure(.registrationMissing),
                "missing Claude registration was reported as an unsafe shape"
            )
        }
    }

    private static func rollbackCannotClobberLaterEdits() throws {
        try withTemporaryConfig(fixture: "shared-mcp-codex-config.toml") { url, _ in
            let executor = makeExecutor("rollback-conflict")
            let migration = preview(executor: executor, target: codexTarget(url))
            let token = apply(executor: executor, preview: migration)
            let laterEdit = Data("# user edited after migration\n".utf8)
            try laterEdit.write(to: url)
            require(chmod(url.path, 0o600) == 0, "rollback conflict chmod failed")
            let confirmation = SharedMCPHostRollbackConfirmation(
                tokenID: token.id,
                phrase: SharedMCPHostMigrationExecutor.rollbackConfirmationPhrase
            )
            let result = executor.rollback(token, confirmation: confirmation)
            guard case .failure(.rollbackTargetChanged) = result else {
                return require(false, "rollback clobbered a later edit")
            }
            let afterConflict = try Data(contentsOf: url)
            require(afterConflict == laterEdit, "rollback conflict changed target")
        }
    }

    /// Optional acting check for a user-owned Codex config. It invokes only
    /// `preview`, compares the complete bytes before/after, and never calls
    /// apply or rollback. The path is explicit so the fixture never guesses a
    /// home directory or reads a host config during ordinary CI.
    private static func liveCodexPreviewIsReadOnlyWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["OUROCODE_TEST_LIVE_CODEX_PREVIEW"],
              path.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let before = try Data(contentsOf: url)
        let result = makeExecutor("live-codex-preview").preview(
            target: codexTarget(url),
            endpoint: attestation()
        )
        guard case .success(let migration) = result else {
            return require(false, "live Codex preview rejected the supported entry shape")
        }
        require(migration.diff.entryPath == "mcp_servers.ouroboros", "live Codex preview path drifted")
        require(!String(describing: migration).contains("OUROBOROS_"), "live Codex preview exposed environment keys")
        let after = try Data(contentsOf: url)
        require(after == before, "live Codex preview mutated the host configuration")
    }

    private static func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private static func filePermissions(_ url: URL) -> mode_t {
        var info = stat()
        require(lstat(url.path, &info) == 0, "could not stat fixture")
        return info.st_mode & 0o777
    }
}
