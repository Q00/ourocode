import Darwin
import Foundation

// Standalone fixture. Run from apps/macos/OurocodeDesktop:
// swiftc Sources/OurocodeDesktop/SharedOuroborosService.swift \
//   Tests/SharedOuroborosServiceFixture.swift \
//   -o /tmp/shared-ouroboros-service-fixture && \
//   /tmp/shared-ouroboros-service-fixture

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SharedOuroborosServiceFixture {
    private static let fixtureToken = String(repeating: "a", count: 64)

    static func main() {
        protocolVersionNegotiationAcceptsPinnedFastMCP()
        wrongVersionFailsClosed()
        capabilityTimeoutFailsClosed()
        actualDoctorOutputParsesWithoutTrustingExitCode()
        authenticationPolicyFailsClosed()
        directPass()
        officialMissingExtrasUsesPinnedUVX()
        managedRuntimeMaterializesAtomically()
        invalidOverrideFailsClosed()
        exactAndConflictingExistingContracts()
        exactLegacyServiceMigration()
        existingExactServiceAttachesBeforeProbeOrLaunchctl()
        secureActivationWritesAndPinsEmptyBridge()
        boundedReadinessUsesDeadlineAndAttemptCaps()
        runtimeRetryReusesExactRequest()
        actualInstalledProfileIfPresent()
        liveManagedRuntimeIfRequested()
        liveReadinessIfRequested()
        liveActivationIfRequested()
        print("PASS: shared Ouroboros 0.51.6 resolver, durable offline runtime, and immutable launch contract")
    }

    private static func protocolVersionNegotiationAcceptsPinnedFastMCP() {
        require(
            OuroborosMCPProtocolVersion.accepts("2025-06-18"),
            "preferred MCP protocol revision was rejected"
        )
        require(
            OuroborosMCPProtocolVersion.accepts("2025-03-26"),
            "Ouroboros 0.51.6 FastMCP revision was rejected"
        )
        require(
            !OuroborosMCPProtocolVersion.accepts("2024-11-05"),
            "an unaudited MCP protocol revision was accepted"
        )
        require(
            !OuroborosMCPProtocolVersion.accepts(nil),
            "a missing MCP protocol revision was accepted"
        )
    }

    private static func runtimeRetryReusesExactRequest() {
        let callLock = NSLock()
        var calls: [[String]] = []
        let endpoint = SharedOuroborosResolver.defaultEndpoint
        let managedEndpoint = OuroborosManagedEndpoint(
            endpoint: endpoint,
            bearerToken: fixtureToken
        )!
        let runtime = SharedOuroborosServiceRuntime(
            queue: DispatchQueue(label: "com.ourolabs.ourocode.fixture.shared-retry"),
            startOperation: { ouroborosPath, uvxPath, bridgeConfigPath, homeDirectory in
                callLock.lock()
                calls.append([
                    ouroborosPath,
                    uvxPath ?? "<nil>",
                    bridgeConfigPath,
                    homeDirectory,
                ])
                let attempt = calls.count
                callLock.unlock()
                if attempt == 1 {
                    return .failure(.activation(.readinessTimedOut))
                }
                return .success(managedEndpoint)
            }
        )
        let expectedRequest = [
            "/opt/ouroboros/bin/ouroboros",
            "/opt/homebrew/bin/uvx",
            "/private/tmp/ourocode-fixture/bridge.yaml",
            "/Users/fixture",
        ]

        let first = awaitRuntimeResult { completion in
            runtime.start(
                ouroborosPath: expectedRequest[0],
                uvxPath: expectedRequest[1],
                bridgeConfigPath: expectedRequest[2],
                homeDirectory: expectedRequest[3],
                completion: completion
            )
        }
        guard case .failure(.activation(.readinessTimedOut)) = first else {
            require(false, "runtime fixture did not preserve the first startup failure")
            return
        }

        let retried = awaitRuntimeResult { completion in
            runtime.retry(completion: completion)
        }
        guard case .success(let retriedEndpoint) = retried else {
            require(false, "runtime did not retry a cached transient failure")
            return
        }
        require(retriedEndpoint == managedEndpoint, "runtime retry returned a different endpoint")
        callLock.lock()
        let recordedCalls = calls
        callLock.unlock()
        require(recordedCalls == [expectedRequest, expectedRequest], "runtime retry rediscovered or mutated its pinned request")
    }

    private static func awaitRuntimeResult(
        _ start: (@escaping SharedOuroborosServiceRuntime.Completion) -> Void
    ) -> Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure> {
        var result: Result<OuroborosManagedEndpoint, SharedOuroborosStartupFailure>?
        start { result = $0 }
        let deadline = Date().addingTimeInterval(2)
        while result == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let result else {
            require(false, "shared runtime callback timed out")
            return .failure(.invalidBridgeConfig)
        }
        return result
    }

    private static func probe(
        path: String = "/opt/ouroboros/bin/ouroboros",
        version: BoundedProbeResult<OuroborosServiceVersion> = .value(.init(major: 0, minor: 51, patch: 6)),
        capability: BoundedProbeResult<OuroborosMCPCapability>
    ) -> OuroborosExecutableProbe {
        OuroborosExecutableProbe(
            executablePath: path,
            isExecutable: true,
            version: version,
            mcpCapability: capability
        )
    }

    private static func authenticationPolicyFailsClosed() {
        require(SharedOuroborosBearerToken.isValid(fixtureToken), "fixture token is invalid")
        require(
            SharedOuroborosBearerToken.isValid(SharedOuroborosBearerToken.generate()),
            "generated bearer token violates the closed format"
        )

        var managed = URLRequest(url: SharedOuroborosResolver.defaultEndpoint)
        require(
            OuroborosRequestAuthorizationPolicy.authorize(
                &managed,
                trust: .managedAuthenticated,
                bearerToken: fixtureToken
            ),
            "managed request rejected its valid credential"
        )
        require(
            managed.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixtureToken)",
            "managed request omitted its bearer header"
        )

        var invalid = URLRequest(url: SharedOuroborosResolver.defaultEndpoint)
        require(
            !OuroborosRequestAuthorizationPolicy.authorize(
                &invalid,
                trust: .managedAuthenticated,
                bearerToken: "short"
            ),
            "managed request accepted a malformed credential"
        )
        require(
            invalid.value(forHTTPHeaderField: "Authorization") == nil,
            "malformed credential reached a request header"
        )

        var external = URLRequest(url: SharedOuroborosResolver.defaultEndpoint)
        require(
            !OuroborosRequestAuthorizationPolicy.authorize(
                &external,
                trust: .explicitUserConfigured,
                bearerToken: fixtureToken
            ),
            "managed credential could leak to an external endpoint"
        )
        require(
            external.value(forHTTPHeaderField: "Authorization") == nil,
            "external endpoint received the managed credential"
        )
    }

    private static func wrongVersionFailsClosed() {
        let result = SharedOuroborosResolver.resolve(.init(
            executableOverride: "/opt/ouroboros/bin/ouroboros",
            installedOuroboros: probe(
                version: .value(.init(major: 0, minor: 51, patch: 0)),
                capability: .value(.officialDistributionMissingMCPExtras)
            ),
            uvx: .init(
                executablePath: "/opt/homebrew/bin/uvx",
                isExecutable: true,
                mcpCapability: .value(.mcpV2Supported)
            )
        ))
        require(result == .failure(.wrongVersion(found: .init(major: 0, minor: 51, patch: 0))), "wrong version fell through to uvx")
    }

    private static func capabilityTimeoutFailsClosed() {
        let result = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .timeout),
            uvx: .init(
                executablePath: "/opt/homebrew/bin/uvx",
                isExecutable: true,
                mcpCapability: .value(.mcpV2Supported)
            )
        ))
        require(result == .failure(.doctorTimedOut), "doctor timeout fell through to uvx")
    }

    private static func actualDoctorOutputParsesWithoutTrustingExitCode() {
        let direct = """
          ✓  ouroboros_version: ouroboros-ai 0.51.6
          ✗  mcp_import: mcp 1.29.0 is not the required MCP 2 runtime
        """
        require(
            SharedOuroborosRuntimeProbe.parseMCPCapability(
                direct,
                exitCode: 1,
                officialInstalledProfile: true
            ) == .value(.officialDistributionMissingMCPExtras),
            "actual installed 0.51.6 doctor result did not select isolated fallback"
        )
        let isolated = """
          ✓  ouroboros_version: ouroboros-ai 0.51.6
          ✓  mcp_import: mcp 2.0.0
          ✗  claude_agent_sdk_import: configured runtime is unavailable
        """
        require(
            SharedOuroborosRuntimeProbe.parseMCPCapability(
                isolated,
                exitCode: 1,
                officialInstalledProfile: false
            ) == .value(.mcpV2Supported),
            "MCP 2 capability was coupled to an unrelated doctor failure"
        )
        let isolatedJSON = """
        [
          {"name":"ouroboros_version","status":"pass","message":"ouroboros-ai 0.51.6","remediation":""},
          {"name":"mcp_import","status":"pass","message":"mcp 2.0.0","remediation":""},
          {"name":"claude_agent_sdk_import","status":"fail","message":"not installed","remediation":""}
        ]
        """
        require(
            SharedOuroborosRuntimeProbe.parseMCPCapability(
                isolatedJSON,
                exitCode: 1,
                officialInstalledProfile: false
            ) == .value(.mcpV2Supported),
            "machine-readable MCP 2 capability was not parsed"
        )
        require(
            SharedOuroborosRuntimeProbe.parseVersion(
                "Ouroboros version 0.51.6\n",
                exitCode: 0
            ) == .value(.init(major: 0, minor: 51, patch: 6)),
            "actual --version output did not parse"
        )
        require(
            SharedOuroborosRuntimeProbe.parseVersion(
                "launcher notice\n\u{001B}[32mOuroboros version 0.51.6\u{001B}[0m\n",
                exitCode: 0
            ) == .value(.init(major: 0, minor: 51, patch: 6)),
            "decorated GUI-launch version output did not parse exactly"
        )
    }

    private static func directPass() {
        let result = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported))
        ))
        guard case .success(let contract) = result else {
            require(false, "supported installed Ouroboros did not resolve")
            return
        }
        require(contract.serviceVersion.description == "0.51.6", "version drifted")
        require(contract.endpoint.absoluteString == "http://127.0.0.1:8976/mcp", "endpoint drifted")
        require(contract.endpointTrust == .managedAuthenticated, "managed endpoint trust changed")
        require(
            OuroborosTargetOverlayTrustPolicy.permitsReadOnlyDiscovery(contract.endpointTrust),
            "managed loopback endpoint stopped exposing bounded target discovery"
        )
        require(
            OuroborosTargetOverlayTrustPolicy.permitsAdvertisedDeliveryModes(contract.endpointTrust),
            "managed authenticated endpoint lost steering delivery modes"
        )
        require(
            !OuroborosTargetOverlayTrustPolicy.permitsAdvertisedDeliveryModes(.explicitUserConfigured),
            "external configured endpoint incorrectly gained steering authority"
        )
        require(
            !OuroborosTargetOverlayTrustPolicy.permitsAdvertisedDeliveryModes(.localUnauthenticated),
            "unauthenticated loopback endpoint incorrectly gained steering authority"
        )
        require(contract.workingDirectory == "/Users/ourocode", "shared service working directory drifted")
        require(contract.executablePath == "/opt/ouroboros/bin/ouroboros", "installed executable was not first")
        require(contract.arguments == SharedOuroborosResolver.directArguments, "direct arguments drifted")
    }

    private static func officialMissingExtrasUsesPinnedUVX() {
        let result = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.officialDistributionMissingMCPExtras)),
            uvx: .init(
                executablePath: "/opt/homebrew/bin/uvx",
                isExecutable: true,
                mcpCapability: .value(.mcpV2Supported)
            )
        ))
        guard case .success(let contract) = result else {
            require(false, "official missing extras did not use uvx")
            return
        }
        require(contract.invocation == .isolatedUVX, "fallback invocation kind changed")
        require(contract.executablePath == "/opt/homebrew/bin/uvx", "uvx executable changed")
        require(contract.arguments == [
            "--offline", "--no-python-downloads", "--no-config", "--no-env-file",
            "--python", ">=3.12", "--isolated",
            "--from", "ouroboros-ai[mcp]==0.51.6",
            "ouroboros", "mcp", "serve",
            "--runtime", "codex",
            "--transport", "streamable-http",
            "--host", "127.0.0.1",
            "--port", "8976",
        ], "pinned uvx arguments drifted")
    }

    private static func managedRuntimeMaterializesAtomically() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-managed-runtime-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support/Ourocode")
        let toolBin = root.appendingPathComponent("tool-bin")
        let bridge = root.appendingPathComponent("bridge.yaml")
        do {
            try FileManager.default.createDirectory(
                at: support,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            try FileManager.default.createDirectory(
                at: toolBin,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for name in ["uv", "uvx"] {
                let path = toolBin.appendingPathComponent(name)
                try Data("#!/bin/sh\n".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            try SharedOuroborosBridgeConfig.data.write(to: bridge)
        } catch {
            require(false, "managed runtime fixture setup failed: \(error)")
            return
        }

        var calls: [(String, [String], TimeInterval, [String: String])] = []
        let runner: ManagedOuroborosRuntimeMaterializer.CommandRunner = {
            executable, arguments, timeout, environment in
            calls.append((executable, arguments, timeout, environment))
            if arguments.first == "venv", let staging = arguments.last {
                let bin = URL(fileURLWithPath: staging).appendingPathComponent("bin")
                do {
                    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                    for name in ["python", "ouroboros"] {
                        let path = bin.appendingPathComponent(name)
                        try Data("#!/bin/sh\n".utf8).write(to: path)
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
                    }
                } catch {
                    return .launchFailed(exitCode: EIO)
                }
                return .completed(exitCode: 0, output: "")
            }
            if arguments.first == "pip" {
                return .completed(exitCode: 0, output: "")
            }
            if executable.hasSuffix("/bin/python") {
                return .completed(exitCode: 0, output: "ourocode-managed-runtime-ok\n")
            }
            if arguments == ["--version"] {
                return .completed(exitCode: 0, output: "Ouroboros version 0.51.6\n")
            }
            if arguments == ["mcp", "doctor", "--json"] {
                return .completed(exitCode: 0, output: """
                [{"name":"ouroboros_version","status":"pass","message":"ouroboros-ai 0.51.6"},
                 {"name":"mcp_import","status":"pass","message":"mcp 2.0.0"}]
                """)
            }
            return .launchFailed(exitCode: EINVAL)
        }

        let prepared = ManagedOuroborosRuntimeMaterializer.prepare(
            uvxPath: toolBin.appendingPathComponent("uvx").path,
            contractDirectory: support.path,
            bridgeConfigPath: bridge.path,
            homeDirectory: root.path,
            commandRunner: runner
        )
        guard case .success(let executablePath) = prepared else {
            require(false, "managed runtime did not materialize: \(prepared)")
            return
        }
        require(executablePath.contains(ManagedOuroborosRuntimeMaterializer.directoryName),
                "managed runtime escaped its versioned app-owned directory")
        require(calls.first?.1.dropLast() == ManagedOuroborosRuntimeMaterializer.venvArgumentPrefix,
                "relocatable offline venv command drifted")
        require(calls.first?.2 == 30, "managed runtime install was not bounded")
        require(calls.first?.3["UV_OFFLINE"] == "1" &&
                calls.first?.3["UV_NO_CONFIG"] == "1" &&
                calls.first?.3["UV_PYTHON_DOWNLOADS"] == "never",
                "managed runtime install environment could use network or user config")
        guard let pipCall = calls.first(where: { $0.1.first == "pip" }) else {
            require(false, "managed runtime omitted package installation")
            return
        }
        require(pipCall.1.contains("copy") && pipCall.1.last == "ouroboros-ai[mcp]==0.51.6",
                "managed runtime did not copy the exact MCP extra out of uv cache")

        let callCount = calls.count
        let reused = ManagedOuroborosRuntimeMaterializer.prepare(
            uvxPath: toolBin.appendingPathComponent("uvx").path,
            contractDirectory: support.path,
            bridgeConfigPath: bridge.path,
            homeDirectory: root.path,
            commandRunner: runner
        )
        require(reused == .success(executablePath), "exact existing runtime was not reused")
        require(!calls.dropFirst(callCount).contains(where: { $0.1.first == "venv" || $0.1.first == "pip" }),
                "existing runtime was reinstalled instead of revalidated")

        let probed = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.officialDistributionMissingMCPExtras)),
            uvx: .init(
                executablePath: toolBin.appendingPathComponent("uvx").path,
                isExecutable: true,
                mcpCapability: .value(.mcpV2Supported)
            ),
            bridgeConfigPath: bridge.path,
            workingDirectory: root.path
        ))
        guard case .success(let ephemeral) = probed,
              case .success(let durable) = SharedOuroborosResolver.pinManagedRuntime(
                  ephemeral,
                  executablePath: executablePath
              ) else {
            require(false, "probed uvx contract could not pin its managed runtime")
            return
        }
        require(durable.invocation == .managedToolRuntime &&
                durable.arguments == SharedOuroborosResolver.directArguments &&
                SharedOuroborosResolver.validate(durable),
                "launchd contract still depends on uvx")
    }

    private static func invalidOverrideFailsClosed() {
        let relative = SharedOuroborosResolver.resolve(.init(
            executableOverride: "bin/ouroboros",
            installedOuroboros: probe(capability: .value(.mcpV2Supported))
        ))
        require(relative == .failure(.invalidOverride), "relative override was accepted")

        let mismatch = SharedOuroborosResolver.resolve(.init(
            executableOverride: "/different/ouroboros",
            installedOuroboros: probe(capability: .value(.mcpV2Supported))
        ))
        require(mismatch == .failure(.invalidOverride), "unprobed override was accepted")
    }

    private static func exactAndConflictingExistingContracts() {
        let resolved = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported))
        ))
        guard case .success(let contract) = resolved else {
            require(false, "fixture contract did not resolve")
            return
        }
        let initial = SharedOuroborosServiceSupervisor.activationPlan(
            contract: contract,
            proposedBearerToken: fixtureToken,
            existingPlist: .missing,
            existingContract: .missing
        )
        guard case .success(let initialPlan) = initial else {
            require(false, "missing artifacts did not produce a plan")
            return
        }
        require(initialPlan.shouldWritePlist && initialPlan.shouldWriteContract, "missing artifacts were not scheduled")

        let exact = SharedOuroborosServiceSupervisor.activationPlan(
            contract: contract,
            proposedBearerToken: String(repeating: "b", count: 64),
            existingPlist: .exact(initialPlan.plistData),
            existingContract: .exact(initialPlan.contractData)
        )
        guard case .success(let exactPlan) = exact else {
            require(false, "exact existing contract was rejected")
            return
        }
        require(!exactPlan.shouldWritePlist && !exactPlan.shouldWriteContract, "exact artifacts would be replaced")
        require(exactPlan.bearerToken == fixtureToken, "existing credential was silently rotated")

        guard let plistValue = try? PropertyListSerialization.propertyList(
            from: initialPlan.plistData,
            format: nil
        ),
        let binaryPlist = try? PropertyListSerialization.data(
            fromPropertyList: plistValue,
            format: .binary,
            options: 0
        ) else {
            require(false, "fixture plist could not be reserialized")
            return
        }
        let semanticallyExact = SharedOuroborosServiceSupervisor.activationPlan(
            contract: contract,
            proposedBearerToken: String(repeating: "c", count: 64),
            existingPlist: .exact(binaryPlist),
            existingContract: .exact(initialPlan.contractData)
        )
        guard case .success(let semanticPlan) = semanticallyExact else {
            require(false, "semantically exact plist was rejected due to serialization bytes")
            return
        }
        require(!semanticPlan.shouldWritePlist, "equivalent plist would be replaced")

        var conflictingData = initialPlan.contractData
        conflictingData.append(0x20)
        let conflict = SharedOuroborosServiceSupervisor.activationPlan(
            contract: contract,
            proposedBearerToken: fixtureToken,
            existingPlist: .exact(initialPlan.plistData),
            existingContract: .exact(conflictingData)
        )
        require(conflict == .failure(.existingContractConflicts), "conflicting contract would be replaced")

        guard let plist = try? PropertyListSerialization.propertyList(
            from: initialPlan.plistData,
            format: nil
        ) as? [String: Any],
        let environment = plist["EnvironmentVariables"] as? [String: String] else {
            require(false, "launchd environment was not serialized")
            return
        }
        require(
            environment == [
                "OUROBOROS_MCP_CONFIG": contract.bridgeConfigPath,
                SharedOuroborosBearerToken.environmentKey: fixtureToken,
                "HOME": contract.workingDirectory,
            ],
            "launchd lost the shared bridge configuration"
        )
        require(
            plist["WorkingDirectory"] as? String == contract.workingDirectory,
            "launchd would scan sessions from the filesystem root"
        )
        require(plist["KeepAlive"] as? Bool == true, "shared service is not retained by launchd")
        require(
            plist["Sockets"] == nil && plist["MachServices"] == nil,
            "HTTP readiness was incorrectly promoted into a private authority transport"
        )
        let programArguments = plist["ProgramArguments"] as? [String] ?? []
        require(
            !programArguments.contains("--auth-token")
                && !programArguments.contains(fixtureToken)
                && !String(decoding: initialPlan.contractData, as: UTF8.self).contains(fixtureToken),
            "bearer token leaked into argv or the non-secret contract"
        )
        require(
            !programArguments.contains("--session-message-upstream-fd")
                && !programArguments.contains("--principal-registration-fd"),
            "shared MCP launch unexpectedly claimed broker authority descriptors"
        )
    }

    private static func exactLegacyServiceMigration() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-legacy-migration-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents").path,
            contractDirectory: root.appendingPathComponent("Application Support/Ourocode").path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                atPath: paths.launchAgentsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                atPath: paths.contractDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for (index, legacyInfo) in SharedOuroborosResolver.knownLegacyServices.enumerated() {
                let invocation: OuroborosSharedInvocation = index == 0 ? .isolatedUVX : .installedOuroboros
                let arguments: [String]
                switch invocation {
                case .installedOuroboros:
                    arguments = SharedOuroborosResolver.directArguments
                case .isolatedUVX:
                    let version = legacyInfo.version
                    arguments = Array(SharedOuroborosResolver.isolatedUVXPrefixArguments.dropLast(2)) + [
                        "--from", "ouroboros-ai[mcp]==\(version)",
                        "ouroboros", "mcp", "serve", "--runtime", "codex",
                        "--transport", "streamable-http", "--host", "127.0.0.1", "--port", "8976",
                    ]
                case .managedToolRuntime:
                    require(false, "v2 legacy fixture selected a managed v4 runtime")
                    return
                }
                let legacy = OuroborosSharedLaunchContract(
                    schemaVersion: 2,
                    launchdLabel: legacyInfo.label,
                    serviceVersion: legacyInfo.version,
                    endpoint: SharedOuroborosResolver.defaultEndpoint,
                    endpointTrust: .localUnauthenticated,
                    invocation: invocation,
                    executablePath: invocation == .installedOuroboros ? "/opt/ouroboros/bin/ouroboros" : "/opt/homebrew/bin/uvx",
                    arguments: arguments,
                    bridgeConfigPath: paths.bridgeConfigPath,
                    workingDirectory: "/Users/ourocode"
                )
                guard let contractData = try? encoder.encode(legacy),
                      let plistData = try? PropertyListSerialization.data(
                          fromPropertyList: [
                              "Label": legacy.launchdLabel,
                              "ProgramArguments": legacy.programArguments,
                              "WorkingDirectory": legacy.workingDirectory,
                              "EnvironmentVariables": [
                                  "OUROBOROS_MCP_CONFIG": legacy.bridgeConfigPath,
                                  "HOME": legacy.workingDirectory,
                              ],
                              "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
                              "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
                          ], format: .xml, options: 0
                      ) else {
                    require(false, "legacy migration fixture could not encode artifacts")
                    return
                }
                let plistPath = paths.legacyPlistPath(label: legacyInfo.label)
                let contractPath = paths.legacyContractPath(label: legacyInfo.label)
                try plistData.write(to: URL(fileURLWithPath: plistPath))
                try contractData.write(to: URL(fileURLWithPath: contractPath))
            }
            for legacyInfo in SharedOuroborosResolver.knownLegacyServices {
                let pathsToPin = [
                    paths.legacyPlistPath(label: legacyInfo.label),
                    paths.legacyContractPath(label: legacyInfo.label),
                ]
                for path in pathsToPin {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: path
                    )
                }
            }

            let authenticatedLabel = SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel
            let authenticated = OuroborosSharedLaunchContract(
                schemaVersion: 3,
                launchdLabel: authenticatedLabel,
                serviceVersion: SharedOuroborosResolver.requiredVersion,
                endpoint: SharedOuroborosResolver.defaultEndpoint,
                endpointTrust: .managedAuthenticated,
                invocation: .isolatedUVX,
                executablePath: "/opt/homebrew/bin/uvx",
                arguments: SharedOuroborosResolver.isolatedUVXArguments,
                bridgeConfigPath: paths.bridgeConfigPath,
                workingDirectory: "/Users/ourocode"
            )
            let authenticatedContractData = try encoder.encode(authenticated)
            let authenticatedPlistData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "Label": authenticatedLabel,
                    "ProgramArguments": authenticated.programArguments,
                    "WorkingDirectory": authenticated.workingDirectory,
                    "EnvironmentVariables": [
                        "OUROBOROS_MCP_CONFIG": authenticated.bridgeConfigPath,
                        SharedOuroborosBearerToken.environmentKey: fixtureToken,
                        "HOME": authenticated.workingDirectory,
                    ],
                    "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
                    "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
                ],
                format: .xml,
                options: 0
            )
            let authenticatedPaths = [
                paths.legacyPlistPath(label: authenticatedLabel),
                paths.legacyContractPath(label: authenticatedLabel),
            ]
            try authenticatedPlistData.write(to: URL(fileURLWithPath: authenticatedPaths[0]))
            try authenticatedContractData.write(to: URL(fileURLWithPath: authenticatedPaths[1]))
            for path in authenticatedPaths {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        } catch {
            require(false, "legacy migration fixture could not write artifacts: \(error)")
            return
        }

        var launchArguments: [[String]] = []
        let migrated = SharedOuroborosServiceSupervisor().retireLegacyUnauthenticatedService(
            paths: paths,
            launchctlRunner: { executable, arguments, timeout in
                require(executable == "/bin/launchctl", "legacy migration used a foreign executable")
                require(timeout == 3, "legacy migration launchctl timeout drifted")
                launchArguments.append(arguments)
                return launchArguments.count == 1 ? .notFound : .launched
            }
        )
        guard case .success = migrated else {
            require(false, "exact legacy service did not migrate: \(migrated)")
            return
        }
        require(launchArguments.count == SharedOuroborosResolver.knownLegacyServices.count + 1,
                "legacy migration did not retire every known service")
        let expectedRetiredLabels = SharedOuroborosResolver.knownLegacyServices.map { $0.label } + [
            SharedOuroborosResolver.legacyAuthenticatedLaunchdLabel,
        ]
        require(Set(launchArguments.map { $0[1] }) == Set(expectedRetiredLabels.map {
            "gui/\(getuid())/\($0)"
        }), "legacy migration targeted a non-exact launchd job")

        let currentResolved = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported)),
            bridgeConfigPath: paths.bridgeConfigPath,
            workingDirectory: "/Users/ourocode"
        ))
        guard case .success(let currentContract) = currentResolved,
              case .success(let currentPlan) = SharedOuroborosServiceSupervisor.activationPlan(
                  contract: currentContract,
                  proposedBearerToken: fixtureToken,
                  existingPlist: .missing,
                  existingContract: .missing
              ) else {
            require(false, "current service fixture contract did not resolve")
            return
        }
        do {
            try currentPlan.plistData.write(to: URL(fileURLWithPath: paths.plistPath))
            try currentPlan.contractData.write(to: URL(fileURLWithPath: paths.contractPath))
            try SharedOuroborosBridgeConfig.data.write(
                to: URL(fileURLWithPath: paths.bridgeConfigPath)
            )
            for path in [paths.plistPath, paths.contractPath, paths.bridgeConfigPath] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
            }
        } catch {
            require(false, "current service fixture artifacts could not be written: \(error)")
            return
        }
        var retainedCurrentLaunchArguments: [[String]] = []
        let retainedCurrentMigration = SharedOuroborosServiceSupervisor()
            .retireLegacyUnauthenticatedService(
                paths: paths,
                launchctlRunner: { _, arguments, _ in
                    retainedCurrentLaunchArguments.append(arguments)
                    return .launched
                }
            )
        guard case .success = retainedCurrentMigration else {
            require(false, "retained current service blocked legacy retirement")
            return
        }
        require(
            retainedCurrentLaunchArguments.count == expectedRetiredLabels.count,
            "retained current artifacts left predecessor jobs loaded"
        )
        require(
            Set(retainedCurrentLaunchArguments.map { $0[1] }) == Set(expectedRetiredLabels.map {
                "gui/\(getuid())/\($0)"
            }),
            "retained current artifacts changed the exact predecessor retirement set"
        )

        let conflictedLabel = SharedOuroborosResolver.knownLegacyServices[1].label
        let conflictedPath = paths.legacyContractPath(label: conflictedLabel)
        guard let originalConflicting = try? Data(contentsOf: URL(fileURLWithPath: conflictedPath)) else {
            require(false, "legacy migration fixture lost its contract")
            return
        }
        var conflicting = originalConflicting
        conflicting.append(0x20)
        try? conflicting.write(to: URL(fileURLWithPath: conflictedPath))
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: conflictedPath
        )
        var bootoutCount = 0
        let rejected = SharedOuroborosServiceSupervisor().retireLegacyUnauthenticatedService(
            paths: paths,
            launchctlRunner: { _, _, _ in
                bootoutCount += 1
                return .launched
            }
        )
        guard case .failure(.existingContractConflicts) = rejected else {
            require(false, "conflicting legacy contract did not fail closed")
            return
        }
        require(bootoutCount == 0, "partial legacy validation did not abort before launchctl")
    }

    private static func existingExactServiceAttachesBeforeProbeOrLaunchctl() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-existing-attach-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path,
            contractDirectory: home.appendingPathComponent("Library/Application Support/Ourocode").path
        )
        let resolved = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported)),
            bridgeConfigPath: paths.bridgeConfigPath,
            workingDirectory: home.path
        ))
        guard case .success(let contract) = resolved else {
            require(false, "existing attach fixture contract did not resolve")
            return
        }
        let planned = SharedOuroborosServiceSupervisor.activationPlan(
            contract: contract,
            proposedBearerToken: fixtureToken,
            existingPlist: .missing,
            existingContract: .missing
        )
        guard case .success(let plan) = planned else {
            require(false, "existing attach fixture plan did not resolve")
            return
        }

        do {
            try FileManager.default.createDirectory(
                atPath: paths.launchAgentsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                atPath: paths.contractDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try plan.plistData.write(to: URL(fileURLWithPath: paths.plistPath))
            try plan.contractData.write(to: URL(fileURLWithPath: paths.contractPath))
            try SharedOuroborosBridgeConfig.data.write(
                to: URL(fileURLWithPath: paths.bridgeConfigPath)
            )
            for path in [paths.plistPath, paths.contractPath, paths.bridgeConfigPath] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
            }
        } catch {
            require(false, "existing attach fixture artifacts could not be written: \(error)")
            return
        }

        let counterLock = NSLock()
        var readinessCalls = 0
        var probeCalls = 0
        var activationCalls = 0
        let supervisor = SharedOuroborosServiceSupervisor()
        let runtime = SharedOuroborosServiceRuntime(
            queue: DispatchQueue(label: "com.ourolabs.ourocode.fixture.existing-attach"),
            existingAttachOperation: { requestedPaths in
                supervisor.attachToExistingService(
                    paths: requestedPaths,
                    readinessPolicy: .init(
                        maximumAttempts: 2,
                        interval: 0,
                        probeTimeout: 0.01,
                        maximumDuration: 0.1
                    ),
                    readinessProbe: { endpoint, bearerToken, _ in
                        require(endpoint == contract.endpoint, "existing attach probed a different endpoint")
                        require(bearerToken == fixtureToken, "existing attach did not recover the pinned credential")
                        counterLock.lock()
                        readinessCalls += 1
                        let ready = readinessCalls == 2
                        counterLock.unlock()
                        return ready
                    }
                )
            },
            probeOperation: { _, _, _ in
                counterLock.lock()
                probeCalls += 1
                counterLock.unlock()
                return (probe(capability: .value(.mcpV2Supported)), nil)
            },
            activationOperation: { contract, bearerToken, _ in
                counterLock.lock()
                activationCalls += 1
                counterLock.unlock()
                return .success(OuroborosManagedEndpoint(
                    endpoint: contract.endpoint,
                    bearerToken: bearerToken
                )!)
            }
        )
        let attached = awaitRuntimeResult { completion in
            runtime.start(
                ouroborosPath: "/opt/ouroboros/bin/ouroboros",
                uvxPath: "/opt/homebrew/bin/uvx",
                bridgeConfigPath: "/bundle/config/is-not-read-on-attach.yaml",
                homeDirectory: home.path,
                completion: completion
            )
        }
        guard case .success(let endpoint) = attached else {
            require(false, "exact existing service did not attach: \(attached)")
            return
        }
        require(endpoint.endpoint == contract.endpoint, "existing attach returned a different endpoint")
        require(endpoint.bearerToken == fixtureToken, "existing attach returned a different token")
        counterLock.lock()
        let recordedReadinessCalls = readinessCalls
        let recordedProbeCalls = probeCalls
        let recordedActivationCalls = activationCalls
        counterLock.unlock()
        require(recordedReadinessCalls == 2, "existing attach did not recover after the first readiness miss")
        require(recordedProbeCalls == 0, "existing attach executed an executable probe")
        require(recordedActivationCalls == 0, "existing attach reached launchctl activation")

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: paths.contractPath
            )
        } catch {
            require(false, "fixture could not make the contract unsafe")
            return
        }
        let unsafe = supervisor.attachToExistingService(
            paths: paths,
            readinessProbe: { _, _, _ in true }
        )
        require(unsafe == .failure(.unsafeExistingArtifact), "unsafe existing artifact did not fail closed")

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.contractPath
            )
            var conflictingContract = plan.contractData
            conflictingContract.append(0x20)
            try conflictingContract.write(to: URL(fileURLWithPath: paths.contractPath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.contractPath
            )
        } catch {
            require(false, "fixture could not make the contract conflicting")
            return
        }
        let conflict = supervisor.attachToExistingService(
            paths: paths,
            readinessProbe: { _, _, _ in true }
        )
        require(
            conflict == .failure(.existingContractConflicts),
            "conflicting existing contract did not fail closed"
        )
    }

    private static func actualInstalledProfileIfPresent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ouroboros = home.appendingPathComponent(".local/bin/ouroboros").path
        let uvx = home.appendingPathComponent(".local/bin/uvx").path
        let candidates = [
            "Resources/ouroboros-mcp-bridge-cua.yaml",
            "apps/macos/OurocodeDesktop/Resources/ouroboros-mcp-bridge-cua.yaml",
        ]
        guard FileManager.default.isExecutableFile(atPath: ouroboros),
              FileManager.default.isExecutableFile(atPath: uvx),
              let bridge = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                .map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return }

        let inspected = SharedOuroborosRuntimeProbe.inspect(
            ouroborosPath: ouroboros,
            uvxPath: uvx,
            bridgeConfigPath: bridge
        )
        guard inspected.0.version == .value(.init(major: 0, minor: 51, patch: 6)) else {
            return
        }
        require(
            inspected.0.mcpCapability == .value(.officialDistributionMissingMCPExtras),
            "installed Ouroboros profile capability changed"
        )
        require(
            inspected.1?.mcpCapability == .value(.mcpV2Supported),
            "cached offline uvx MCP 2 profile is unavailable"
        )
    }

    private static func secureActivationWritesAndPinsEmptyBridge() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-shared-service-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents").path,
            contractDirectory: root.appendingPathComponent("Application Support/Ourocode").path
        )
        let resolved = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported)),
            bridgeConfigPath: paths.bridgeConfigPath
        ))
        guard case .success(let contract) = resolved else {
            require(false, "secure activation contract did not resolve")
            return
        }

        var readinessCalls = 0
        let activated = SharedOuroborosServiceSupervisor().activateSharedService(
            contract: contract,
            proposedBearerToken: fixtureToken,
            paths: paths,
            launchctlRunner: { _, _, _ in .launched },
            readinessProbe: { _, bearerToken, _ in
                require(bearerToken == fixtureToken, "readiness did not use the launch credential")
                readinessCalls += 1
                return readinessCalls >= 2
            }
        )
        if case .failure(let failure) = activated {
            require(false, "secure activation fixture failed: \(failure)")
        }
        let bridgeContents = try? String(contentsOfFile: paths.bridgeConfigPath, encoding: .utf8)
        require(
            bridgeContents == String(decoding: SharedOuroborosBridgeConfig.data, as: UTF8.self),
            "fixed bridge config did not enable the pinned CUA bridge"
        )
        var info = stat()
        require(lstat(paths.bridgeConfigPath, &info) == 0, "fixed bridge config is missing")
        require((info.st_mode & 0o777) == 0o600, "fixed bridge config is not owner-only")
        for path in [paths.plistPath, paths.contractPath] {
            require(lstat(path, &info) == 0, "managed service artifact is missing")
            require((info.st_mode & 0o777) == 0o600, "managed service artifact is not owner-only")
            require(info.st_uid == getuid(), "managed service artifact has a foreign owner")
        }
        let plistText = (try? String(contentsOfFile: paths.plistPath, encoding: .utf8)) ?? ""
        let contractText = (try? String(contentsOfFile: paths.contractPath, encoding: .utf8)) ?? ""
        require(plistText.contains(fixtureToken), "launchd environment omitted the bearer token")
        require(!contractText.contains(fixtureToken), "non-secret contract persisted the bearer token")

        try? Data("mcp_servers: [unsafe]\n".utf8).write(
            to: URL(fileURLWithPath: paths.bridgeConfigPath),
            options: .atomic
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.bridgeConfigPath
        )
        let conflict = SharedOuroborosServiceSupervisor().activateSharedService(
            contract: contract,
            proposedBearerToken: fixtureToken,
            paths: paths,
            launchctlRunner: { _, _, _ in .launched },
            readinessProbe: { _, _, _ in true }
        )
        guard case .failure(.existingBridgeConfigConflicts) = conflict else {
            require(false, "conflicting bridge config was accepted or replaced")
            return
        }
    }

    private static func boundedReadinessUsesDeadlineAndAttemptCaps() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-readiness-policy-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents").path,
            contractDirectory: root.appendingPathComponent("Application Support/Ourocode").path
        )
        let resolved = SharedOuroborosResolver.resolve(.init(
            installedOuroboros: probe(capability: .value(.mcpV2Supported)),
            bridgeConfigPath: paths.bridgeConfigPath
        ))
        guard case .success(let contract) = resolved else {
            require(false, "readiness fixture contract did not resolve")
            return
        }

        var readinessCalls = 0
        let timedOut = SharedOuroborosServiceSupervisor().activateSharedService(
            contract: contract,
            proposedBearerToken: fixtureToken,
            paths: paths,
            readinessPolicy: .init(
                maximumAttempts: 3,
                interval: 0,
                probeTimeout: 0.01,
                maximumDuration: 0.1
            ),
            launchctlRunner: { _, _, _ in .launched },
            readinessProbe: { _, _, _ in
                readinessCalls += 1
                return false
            }
        )
        guard case .failure(.readinessTimedOut) = timedOut else {
            require(false, "bounded readiness did not time out")
            return
        }
        require(readinessCalls == 4, "readiness exceeded its initial probe plus attempt cap")

        let invalid = SharedOuroborosServiceSupervisor().activateSharedService(
            contract: contract,
            proposedBearerToken: fixtureToken,
            paths: paths,
            readinessPolicy: .init(
                maximumAttempts: 1,
                interval: 0,
                probeTimeout: 0.1,
                maximumDuration: 31
            ),
            launchctlRunner: { _, _, _ in .launched },
            readinessProbe: { _, _, _ in true }
        )
        guard case .failure(.invalidPaths) = invalid else {
            require(false, "unbounded readiness policy was accepted")
            return
        }
    }

    private static func liveReadinessIfRequested() {
        guard ProcessInfo.processInfo.environment["OUROCODE_TEST_LIVE_MCP"] == "1" else { return }
        require(
            SharedOuroborosServiceSupervisor.probeReadiness(
                endpoint: SharedOuroborosResolver.defaultEndpoint,
                bearerToken: ProcessInfo.processInfo.environment["OUROBOROS_MCP_AUTH_TOKEN"] ?? fixtureToken,
                timeout: 1
            ),
            "live streamable HTTP endpoint did not negotiate exact Ouroboros 0.51.6"
        )
    }

    private static func liveActivationIfRequested() {
        guard ProcessInfo.processInfo.environment["OUROCODE_TEST_LIVE_ACTIVATION"] == "1" else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let support = home.appendingPathComponent("Library/Application Support/Ourocode")
        let paths = SharedOuroborosServiceSupervisor.Paths(
            launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path,
            contractDirectory: support.path
        )
        let inspected = SharedOuroborosRuntimeProbe.inspect(
            ouroborosPath: home.appendingPathComponent(".local/bin/ouroboros").path,
            uvxPath: home.appendingPathComponent(".local/bin/uvx").path,
            bridgeConfigPath: paths.bridgeConfigPath
        )
        let resolved = SharedOuroborosResolver.resolve(.init(
            executableOverride: home.appendingPathComponent(".local/bin/ouroboros").path,
            installedOuroboros: inspected.0,
            uvx: inspected.1,
            bridgeConfigPath: paths.bridgeConfigPath,
            workingDirectory: home.path
        ))
        guard case .success(var contract) = resolved else {
            require(false, "live activation resolution failed: \(resolved)")
            return
        }
        if contract.invocation == .isolatedUVX {
            let prepared = ManagedOuroborosRuntimeMaterializer.prepare(
                uvxPath: home.appendingPathComponent(".local/bin/uvx").path,
                contractDirectory: support.path,
                bridgeConfigPath: paths.bridgeConfigPath,
                homeDirectory: home.path
            )
            guard case .success(let executable) = prepared,
                  case .success(let durable) = SharedOuroborosResolver.pinManagedRuntime(
                      contract,
                      executablePath: executable
                  ) else {
                require(false, "live activation could not materialize its durable runtime")
                return
            }
            contract = durable
        }
        let activation = SharedOuroborosServiceSupervisor().activateSharedService(
            contract: contract,
            proposedBearerToken: SharedOuroborosBearerToken.generate(),
            paths: paths
        )
        guard case .success = activation else {
            require(false, "live exact service activation failed: \(activation)")
            return
        }
    }

    private static func liveManagedRuntimeIfRequested() {
        guard ProcessInfo.processInfo.environment["OUROCODE_TEST_LIVE_MANAGED_RUNTIME"] == "1" else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let uvx = home.appendingPathComponent(".local/bin/uvx")
        guard FileManager.default.isExecutableFile(atPath: uvx.path) else {
            require(false, "live managed runtime fixture requires ~/.local/bin/uvx")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-live-managed-runtime-\(UUID().uuidString)")
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support/Ourocode")
        let bridge = root.appendingPathComponent("bridge.yaml")
        do {
            try FileManager.default.createDirectory(
                at: support,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
            try SharedOuroborosBridgeConfig.data.write(to: bridge)
        } catch {
            require(false, "live managed runtime setup failed: \(error)")
            return
        }
        let prepared = ManagedOuroborosRuntimeMaterializer.prepare(
            uvxPath: uvx.path,
            contractDirectory: support.path,
            bridgeConfigPath: bridge.path,
            homeDirectory: home.path
        )
        guard case .success(let executable) = prepared else {
            require(false, "live offline managed runtime preparation failed: \(prepared)")
            return
        }
        let runtime = ManagedOuroborosRuntimeMaterializer.runtimeDirectory(
            contractDirectory: support.path
        )
        require(executable == (runtime as NSString).appendingPathComponent("bin/ouroboros"),
                "live managed runtime executable path drifted")
        require(ManagedOuroborosRuntimeMaterializer.validate(
            runtimeDirectory: runtime,
            bridgeConfigPath: bridge.path,
            homeDirectory: home.path
        ), "live managed runtime failed a second lazy-import validation")
    }
}
