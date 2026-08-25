import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionWorkspaceProjectionFixture {
    static func main() {
        let projected = SessionWorkspaceProjectionPolicy.resolve([
            SessionWorkspaceExecution(
                sessionID: "session-a", executionID: "exec-2", status: "running",
                sortKey: "2026-08-25T02:00:00", agentIDs: ["agent-b", "agent-c"]
            ),
            SessionWorkspaceExecution(
                sessionID: "session-a", executionID: "exec-1", status: "completed",
                sortKey: "2026-08-25T01:00:00", agentIDs: ["agent-a", "agent-b"]
            ),
            SessionWorkspaceExecution(
                sessionID: "session-b", executionID: "exec-3", status: "completed",
                sortKey: "2026-08-24T01:00:00", agentIDs: []
            ),
        ])
        require(projected.count == 2, "executions were not grouped by stable session id")
        require(projected[0].sessionID == "session-a", "latest session did not sort first")
        require(projected[0].executionIDs == ["exec-2", "exec-1"], "session execution order drifted")
        require(projected[0].agentIDs == ["agent-b", "agent-c", "agent-a"], "agents were not multiplexed exactly once")
        require(projected[0].status == "running", "one live execution did not keep the session live")
        require(projected[1].status == "completed", "completed session status changed")
        print("PASS: stable sessions multiplex executions and exact agents without duplicates")
    }
}
