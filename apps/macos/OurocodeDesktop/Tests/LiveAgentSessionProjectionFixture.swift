import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func binding(
    _ attempt: String,
    sessionID: String,
    depth: Int,
    parentAgentID: String? = nil
) -> TerminalSessionBinding {
    TerminalSessionBinding(
        surface: OuroborosPTYSurfaceBindingV1(
            identity: TerminalSessionLeafIdentity(
                sourceID: "ouroboros",
                sessionID: sessionID,
                executionID: "exec-a",
                scopeID: "scope-\(attempt)",
                attemptID: attempt
            ),
            terminalID: "pty-\(attempt)",
            brokerGeneration: 7
        ),
        label: attempt,
        status: "running",
        depth: depth,
        parentAgentID: parentAgentID
    )
}

@main
private enum LiveAgentSessionProjectionFixture {
    static func main() {
        let parentBinding = binding("parent", sessionID: "parent-session", depth: 0)
        let parent = LiveTerminalSession(
            id: UUID(), title: "Claude parent", path: "/fixture",
            selected: true, running: true, foregroundProcess: true,
            binding: parentBinding
        )
        let child = LiveTerminalSession(
            id: UUID(), title: "Explore child", path: "/fixture",
            selected: false, running: true, foregroundProcess: true,
            binding: binding(
                "child",
                sessionID: "child-session",
                depth: 1,
                parentAgentID: parentBinding.agentID
            )
        )
        let sameSessionPeer = LiveTerminalSession(
            id: UUID(), title: "Independent peer", path: "/fixture",
            selected: false, running: true, foregroundProcess: true,
            binding: binding("peer", sessionID: "parent-session", depth: 1)
        )
        let plain = LiveTerminalSession(
            id: UUID(), title: "Codex standalone", path: "/other",
            selected: false, running: true, foregroundProcess: true,
            binding: nil
        )
        let result = LiveAgentSessionProjectionPolicy.resolve([
            child, sameSessionPeer, plain, parent,
        ])
        require(result.count == 3, "only explicit parent identity may group agents")
        let grouped = result.first { $0.terminals.count == 2 }
        require(grouped?.terminals.map(\.title) == ["Claude parent", "Explore child"],
                "explicit parent/child agents were not ordered by depth")
        require(grouped?.detail == "2 agents · 2 active", "agent multiplexer summary drifted")
        require(result.contains { $0.title == "Independent peer" },
                "shared session ID incorrectly implied parentage")
        require(result.contains { $0.title == "Codex standalone" },
                "standalone live session disappeared")
        print("PASS: live agent grouping requires explicit provider-owned parent identity")
    }
}
