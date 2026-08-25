import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private struct StdioFixture: Decodable {
    let serverName: String
    let scope: String?
    let namespace: String?
    let executable: String
    let arguments: [String]
    let rollbackSnapshotID: String
    let configGeneration: UInt64
}

private struct FixtureRoot: Decodable {
    let codex: StdioFixture
    let claudeUser: StdioFixture
    let claudeLocal: StdioFixture
    let claudePlugin: StdioFixture
}

@main
private enum SharedMCPHostMigrationPlannerFixture {
    static func main() throws {
        let fixtures = try loadFixtures()
        codexCommandsAreExactAndSecretFree(fixtures.codex)
        claudeUserAndLocalAreDistinct(fixtures.claudeUser, fixtures.claudeLocal)
        claudePluginFailsClosed(fixtures.claudePlugin)
        unrelatedAndNonStdioServersDoNotMigrate()
        endpointMustBeLoopbackAndSupervisorVerified(fixtures.codex)
        rollbackMetadataIsMandatory(fixtures.codex)
        applyRequiresExactExplicitConfirmation(fixtures.codex)
        print("PASS: secret-free shared MCP host migration previews, rollback references, and explicit apply gate")
    }

    private static func loadFixtures() throws -> FixtureRoot {
        let source = URL(fileURLWithPath: #filePath)
        let url = source.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/shared-mcp-host-observations.json")
        return try JSONDecoder().decode(FixtureRoot.self, from: Data(contentsOf: url))
    }

    private static func attestation(
        endpoint: URL = SharedOuroborosResolver.defaultEndpoint,
        ownership: Bool = true,
        readiness: Bool = true
    ) -> SharedMCPEndpointAttestation {
        .init(
            endpoint: endpoint,
            supervisorLabel: SharedOuroborosResolver.sharedLaunchdLabel,
            contractSchemaVersion: 5,
            serviceVersion: SharedOuroborosResolver.requiredVersion,
            ownershipArtifactsVerified: ownership,
            readinessProbeSucceeded: readiness
        )
    }

    private static func observation(
        _ fixture: StdioFixture,
        registration: SharedMCPHostRegistration
    ) -> SharedMCPServerObservation {
        .init(
            registration: registration,
            serverName: fixture.serverName,
            transport: .stdio(executable: fixture.executable, arguments: fixture.arguments),
            rollback: .init(
                snapshotID: fixture.rollbackSnapshotID,
                configGeneration: fixture.configGeneration
            )
        )
    }

    private static func codexCommandsAreExactAndSecretFree(_ fixture: StdioFixture) {
        let result = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(fixture, registration: .codex),
            endpoint: attestation()
        )
        guard case .success(let plan) = result else { return require(false, "Codex stdio was not detected") }
        require(plan.mode == .dryRun, "preview escaped dry-run mode")
        require(plan.commands == [
            .init(arguments: ["codex", "mcp", "remove", "ouroboros"]),
            .init(arguments: [
                "codex", "mcp", "add", "ouroboros", "--url", "http://127.0.0.1:8976/mcp",
            ]),
        ], "Codex migration argv changed")
        let flattened = plan.commands.flatMap(\.arguments).joined(separator: " ").lowercased()
        require(!flattened.contains("token") && !flattened.contains("header") && !flattened.contains("env"), "command exposed secret-bearing fields")
        require(plan.rollback.snapshotID == fixture.rollbackSnapshotID, "rollback snapshot reference was lost")
        require(plan.rollback.configGeneration == fixture.configGeneration, "rollback generation was lost")
    }

    private static func claudeUserAndLocalAreDistinct(_ user: StdioFixture, _ local: StdioFixture) {
        let userResult = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(user, registration: .claude(scope: .user)),
            endpoint: attestation()
        )
        let localResult = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(local, registration: .claude(scope: .local)),
            endpoint: attestation()
        )
        guard case .success(let userPlan) = userResult,
              case .success(let localPlan) = localResult else {
            return require(false, "Claude user/local stdio registration was not detected")
        }
        require(userPlan.commands[0].arguments.suffix(2) == ["--scope", "user"], "Claude user scope was lost")
        require(localPlan.commands[0].arguments.suffix(2) == ["--scope", "local"], "Claude local scope was lost")
        require(userPlan.rollback != localPlan.rollback, "Claude rollback snapshots were conflated")

        let project = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(user, registration: .claude(scope: .project)),
            endpoint: attestation()
        )
        require(project == .failure(.unsupportedClaudeScope(.project)), "unsupported project scope did not fail closed")
    }

    private static func claudePluginFailsClosed(_ fixture: StdioFixture) {
        let namespace = fixture.namespace ?? ""
        let result = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(fixture, registration: .claudePlugin(namespace: namespace)),
            endpoint: attestation()
        )
        require(
            result == .failure(.claudePluginCannotBeDisabledOrOverridden(namespace: namespace)),
            "Claude plugin migration was falsely claimed"
        )
    }

    private static func unrelatedAndNonStdioServersDoNotMigrate() {
        let rollback = SharedMCPRollbackMetadata(snapshotID: "safe.snapshot", configGeneration: 1)
        let unrelated = SharedMCPServerObservation(
            registration: .codex,
            serverName: "ouroboros",
            transport: .stdio(executable: "npx", arguments: ["other-server"]),
            rollback: rollback
        )
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: unrelated, endpoint: attestation()) == .failure(.notOuroboros),
            "unrelated stdio server was migrated"
        )
        let http = SharedMCPServerObservation(
            registration: .codex,
            serverName: "ouroboros",
            transport: .streamableHTTP,
            rollback: rollback
        )
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: http, endpoint: attestation()) == .failure(.notStdio),
            "existing HTTP registration was treated as stdio"
        )
    }

    private static func endpointMustBeLoopbackAndSupervisorVerified(_ fixture: StdioFixture) {
        let observed = observation(fixture, registration: .codex)
        let remote = URL(string: "https://example.com/mcp")!
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: observed, endpoint: attestation(endpoint: remote)) == .failure(.endpointNotLoopback),
            "remote endpoint was accepted"
        )
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: observed, endpoint: attestation(ownership: false)) == .failure(.endpointUnverified),
            "endpoint without owner-artifact proof was accepted"
        )
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: observed, endpoint: attestation(readiness: false)) == .failure(.endpointUnverified),
            "endpoint without readiness proof was accepted"
        )
    }

    private static func rollbackMetadataIsMandatory(_ fixture: StdioFixture) {
        let missing = SharedMCPServerObservation(
            registration: .codex,
            serverName: fixture.serverName,
            transport: .stdio(executable: fixture.executable, arguments: fixture.arguments),
            rollback: nil
        )
        require(
            SharedMCPHostMigrationPlanner.dryRun(observation: missing, endpoint: attestation()) == .failure(.missingOrInvalidRollbackMetadata),
            "migration discarded rollback requirement"
        )
    }

    private static func applyRequiresExactExplicitConfirmation(_ fixture: StdioFixture) {
        let result = SharedMCPHostMigrationPlanner.dryRun(
            observation: observation(fixture, registration: .codex),
            endpoint: attestation()
        )
        guard case .success(let preview) = result else { return require(false, "missing preview") }
        require(
            SharedMCPHostMigrationPlanner.authorizeApply(
                preview,
                confirmation: .init(planID: UUID(), phrase: SharedMCPHostMigrationPlanner.applyConfirmationPhrase)
            ) == .failure(.applyConfirmationMismatch),
            "different plan ID authorized apply"
        )
        require(
            SharedMCPHostMigrationPlanner.authorizeApply(
                preview,
                confirmation: .init(planID: preview.planID, phrase: "yes")
            ) == .failure(.applyConfirmationMismatch),
            "weak confirmation authorized apply"
        )
        let authorized = SharedMCPHostMigrationPlanner.authorizeApply(
            preview,
            confirmation: .init(
                planID: preview.planID,
                phrase: SharedMCPHostMigrationPlanner.applyConfirmationPhrase
            )
        )
        guard case .success(let plan) = authorized else { return require(false, "exact confirmation was rejected") }
        require(plan.mode == .explicitApplyAuthorized, "apply mode was not explicit")
        require(plan.commands == preview.commands && plan.rollback == preview.rollback, "authorization changed reviewed plan")
    }
}
