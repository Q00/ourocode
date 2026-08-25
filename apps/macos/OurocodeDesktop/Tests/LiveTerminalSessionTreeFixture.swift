import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func binding(
    _ attempt: String,
    parentAgentID: String? = nil
) -> TerminalSessionBinding {
    TerminalSessionBinding(
        surface: OuroborosPTYSurfaceBindingV1(
            identity: TerminalSessionLeafIdentity(
                sourceID: "provider",
                sessionID: "session-\(attempt)",
                executionID: "execution",
                scopeID: "scope-\(attempt)",
                attemptID: attempt
            ),
            terminalID: "terminal-\(attempt)",
            brokerGeneration: 9
        ),
        label: attempt,
        status: "running",
        depth: 0,
        parentAgentID: parentAgentID
    )
}

private func terminal(
    _ title: String,
    binding: TerminalSessionBinding
) -> LiveTerminalSession {
    LiveTerminalSession(
        id: UUID(),
        title: title,
        path: "/fixture",
        selected: false,
        running: true,
        foregroundProcess: true,
        binding: binding
    )
}

@main
private enum LiveTerminalSessionTreeFixture {
    static func main() {
        let rootBinding = binding("root")
        let childBinding = binding("child", parentAgentID: rootBinding.agentID)
        let nestedBinding = binding("nested", parentAgentID: childBinding.agentID)
        let peerBinding = binding("peer")
        let roots = LiveTerminalSessionTreePolicy.resolve([
            terminal("Nested", binding: nestedBinding),
            terminal("Peer", binding: peerBinding),
            terminal("Child", binding: childBinding),
            terminal("Root", binding: rootBinding),
        ])
        require(roots.count == 2, "explicit graph did not preserve two roots")
        let root = roots.first { $0.terminal.title == "Root" }
        require(root?.children.map(\.terminal.title) == ["Child"], "child was not nested under parent")
        require(root?.children.first?.children.map(\.terminal.title) == ["Nested"],
                "nested child was flattened")
        require(roots.contains { $0.terminal.title == "Peer" }, "independent peer disappeared")
        print("PASS: session rail tree preserves explicit nested agent lineage")
    }
}
