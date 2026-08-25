import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum MCPSessionActivationFixture {
    static func main() {
        let group = MCPSessionActivation(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: nil,
            attemptID: nil,
            requiresExactAttempt: false,
            generation: 7
        )
        let agent1 = MCPSessionActivation(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1",
            requiresExactAttempt: true,
            generation: 8
        )
        let agent2 = MCPSessionActivation(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: "scope-2",
            attemptID: "attempt-2",
            requiresExactAttempt: true,
            generation: 9
        )
        require(group.attemptFilter == nil, "group history unexpectedly became an attempt query")
        require(agent1 != agent2, "sibling attempts collapsed to one activation")
        require(agent1.attemptFilter?.scopeID == "scope-1", "Agent 1 scope was not retained")
        require(agent2.attemptFilter?.attemptID == "attempt-2", "Agent 2 attempt was not retained")
        require(agent1.attemptFilter != agent2.attemptFilter, "sibling attempts shared one exact filter")

        let staleAgent1 = MCPSessionActivation(
            sourceID: agent1.sourceID,
            sessionID: agent1.sessionID,
            executionID: agent1.executionID,
            scopeID: agent1.scopeID,
            attemptID: agent1.attemptID,
            requiresExactAttempt: true,
            generation: 7
        )
        require(staleAgent1 != agent1, "activation generation did not reject a stale callback")
        require(staleAgent1 != agent2, "late Agent 1 callback matched Agent 2")

        let malformedLeaf = MCPSessionActivation(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: nil,
            attemptID: nil,
            requiresExactAttempt: true,
            generation: 10
        )
        require(malformedLeaf.attemptFilter == nil, "identity-less leaf degraded into group history")

        print("PASS: exact attempt activation separates siblings, stale callbacks, and group history")
    }
}
