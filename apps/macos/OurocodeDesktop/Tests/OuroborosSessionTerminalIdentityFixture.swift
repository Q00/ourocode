import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum OuroborosSessionTerminalIdentityFixture {
    static func main() {
        let target: [String: Any] = [
            "execution_id": "exec-1",
            "session_id": "session-1",
            "target_session_scope_id": "scope-1",
            "target_session_attempt_id": "attempt-1",
            "ac_id": "ac-0",
            "surface": [
                "kind": "pty",
                "terminal_id": "term-7",
                "broker_generation": 42,
            ],
        ]
        let identity = OuroborosSessionTerminalIdentityDecoderV1.identity(
            sourceID: "ouroboros",
            sessionID: "session-1",
            expectedExecutionID: "exec-1",
            target: target
        )
        require(identity != nil, "exact target tuple was rejected")
        guard let identity else { return }
        guard case .pty(let binding) = OuroborosSessionTerminalIdentityDecoderV1.surface(
            target: target,
            identity: identity
        ) else {
            require(false, "valid server-owned PTY surface was not decoded")
            return
        }
        require(binding.terminalID == "term-7", "terminal id was rewritten")
        require(binding.brokerGeneration == 42, "broker generation was not preserved")
        require(binding.identity.scopeID == "scope-1", "scope identity was not preserved")
        require(
            OuroborosSessionTerminalIdentityDecoderV1.stableTabID(for: identity)
                == "attempt:9:ouroboros:9:session-1:6:exec-1:7:scope-1:9:attempt-1",
            "stable tab id did not preserve the exact tuple"
        )
        let delimiterLeft = OuroborosSessionAttemptIdentityV1(
            sourceID: "a:b",
            sessionID: "c",
            executionID: "d",
            scopeID: "e",
            attemptID: "f"
        )
        let delimiterRight = OuroborosSessionAttemptIdentityV1(
            sourceID: "a",
            sessionID: "b:c",
            executionID: "d",
            scopeID: "e",
            attemptID: "f"
        )
        require(
            OuroborosSessionTerminalIdentityDecoderV1.stableTabID(for: delimiterLeft)
                != OuroborosSessionTerminalIdentityDecoderV1.stableTabID(for: delimiterRight),
            "delimiter-bearing identities collided"
        )

        var malformed = target
        malformed["execution_id"] = "other-execution"
        require(
            OuroborosSessionTerminalIdentityDecoderV1.identity(
                sourceID: "ouroboros",
                sessionID: "session-1",
                expectedExecutionID: "exec-1",
                target: malformed
            ) == nil,
            "cross-execution target was accepted"
        )

        var wrongSessionType = target
        wrongSessionType["session_id"] = 7
        require(
            OuroborosSessionTerminalIdentityDecoderV1.identity(
                sourceID: "ouroboros",
                sessionID: "session-1",
                expectedExecutionID: "exec-1",
                target: wrongSessionType
            ) == nil,
            "malformed optional session identity was ignored"
        )

        var noSurface = target
        noSurface.removeValue(forKey: "surface")
        guard let noSurfaceIdentity = OuroborosSessionTerminalIdentityDecoderV1.identity(
            sourceID: "ouroboros",
            sessionID: "session-1",
            expectedExecutionID: "exec-1",
            target: noSurface
        ) else {
            require(false, "target without optional surface was rejected")
            return
        }
        require(
            OuroborosSessionTerminalIdentityDecoderV1.surface(
                target: noSurface,
                identity: noSurfaceIdentity
            ) == .unbound(.notAdvertised),
            "missing surface did not remain explicitly unbound"
        )

        var stale = target
        stale["surface"] = [
            "kind": "pty",
            "terminal_id": "term-7",
            "broker_generation": 0,
        ]
        require(
            OuroborosSessionTerminalIdentityDecoderV1.surface(target: stale, identity: identity)
                == .unbound(.invalidBrokerGeneration),
            "zero broker generation minted a surface binding"
        )

        print("PASS: exact fanout identity, optional PTY surface, and fail-closed unbound states")
    }
}
