import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum OuroborosSessionTargetOverlayPolicyFixture {
    static func main() {
        let identity = OuroborosSessionAttemptIdentityV1(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1"
        )
        var target: String? = "advertised-target"
        var advertisedIdentity: OuroborosSessionAttemptIdentityV1? = identity
        var surface: OuroborosSessionSurfaceResolutionV1 = .pty(
            OuroborosPTYSurfaceBindingV1(
                identity: identity,
                terminalID: "terminal-1",
                brokerGeneration: 9
            )
        )

        require(
            OuroborosSessionTargetOverlayPolicy.revoke(
                target: &target,
                identity: &advertisedIdentity,
                surface: &surface
            ),
            "advertised target overlay was reported unchanged"
        )
        require(target == nil, "target survived discovery revocation")
        require(advertisedIdentity == nil, "attempt identity survived discovery revocation")
        require(surface == .unbound(.notAdvertised), "PTY surface survived discovery revocation")
        require(
            !OuroborosSessionTargetOverlayPolicy.revoke(
                target: &target,
                identity: &advertisedIdentity,
                surface: &surface
            ),
            "already-revoked overlay caused a duplicate publication"
        )

        print("PASS: target, identity, and PTY surface revoke as one fail-closed overlay")
    }
}
