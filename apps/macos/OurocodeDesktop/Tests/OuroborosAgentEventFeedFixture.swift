import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func data(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func agent(
    id: String,
    parentID: String? = nil,
    status: String,
    depth: Int,
    index: Int
) -> [String: Any] {
    [
        "id": id,
        "parent_id": parentID ?? NSNull(),
        "title": "Verify claim \(index)",
        "status": status,
        "depth": depth,
        "ac_index": index,
        "provider": "codex_cli",
        "session_id": NSNull(),
        "tool": index == 2 ? "Read" : NSNull(),
        "model_tier": NSNull(),
        "model": "gpt-5.6",
        "tokens": 42.0,
    ]
}

private func board(executionID: String) -> Data {
    data([
        "meta": [
            "execution_id": executionID,
            "session_id": "orch-1",
            "goal": "Verify architecture",
            "phase": "Deliver",
            "activity": "Reviewing",
        ],
        "columns": [
            "pending": [agent(id: "node-a", status: "pending", depth: 0, index: 1)],
            "executing": [agent(id: "node-b", parentID: "node-a", status: "executing", depth: 1, index: 2)],
            "completed": [],
            "failed": [],
        ],
        "providers": ["codex_cli"],
    ])
}

@main
private enum OuroborosAgentEventFeedFixture {
    static func main() {
        if CommandLine.arguments.contains("--live") {
            runLiveProbe()
            return
        }
        let state = OuroborosDashboardStateDecoder.decode(data([
            "host": "127.0.0.1",
            "port": 51_805,
            "pid": 42,
            "db_path": "/Users/fixture/.ouroboros/data/ouroboros.db",
            "started_at": "2026-08-25T16:33:22.786343+00:00",
        ]))
        require(state?.baseURL.absoluteString == "http://127.0.0.1:51805", "loopback dashboard state was not decoded")
        require(
            state?.eventURL(executionID: "exec:one")?.absoluteString
                == "http://127.0.0.1:51805/events?run=exec:one",
            "execution id was not URL encoded through URLComponents"
        )
        require(OuroborosDashboardStateDecoder.decode(data([
            "host": "example.com", "port": 80, "pid": 1,
            "db_path": "/tmp/db", "started_at": "2026-08-25T16:33:22Z",
        ])) == nil, "non-loopback dashboard was trusted")

        let runs = OuroborosDashboardRunIndexDecoder.executionIDs(data([
            "runs": [["execution_id": "exec-1"], ["execution_id": "exec-2"]],
        ]))
        require(runs == ["exec-1", "exec-2"], "run discovery dropped bounded identities")

        guard let snapshot = OuroborosBoardSnapshotDecoder.decode(
            board(executionID: "exec-1"),
            expectedExecutionID: "exec-1"
        ) else {
            require(false, "valid board snapshot was rejected")
            return
        }
        require(snapshot.sessionID == "orch-1", "session identity was lost")
        require(snapshot.agents.count == 2, "agent cards were not projected")
        require(snapshot.agents[1].parentID == "node-a", "explicit parent identity was lost")
        require(snapshot.agents[1].tool == "Read", "live tool activity was lost")
        require(snapshot.agents[1].tokenSpend == 42, "token telemetry was lost")

        require(
            OuroborosBoardSnapshotDecoder.decode(
                board(executionID: "exec-1"),
                expectedExecutionID: "exec-forged"
            ) == nil,
            "snapshot for a different execution was accepted"
        )
        var cyclic = try! JSONSerialization.jsonObject(with: board(executionID: "exec-1")) as! [String: Any]
        var columns = cyclic["columns"] as! [String: Any]
        var pending = columns["pending"] as! [[String: Any]]
        pending[0]["parent_id"] = "node-b"
        columns["pending"] = pending
        cyclic["columns"] = columns
        require(
            OuroborosBoardSnapshotDecoder.decode(data(cyclic), expectedExecutionID: "exec-1") == nil,
            "cyclic agent lineage was accepted"
        )
        print("PASS: Ouroboros dashboard state, run discovery, and live agent boards fail closed")
    }
    private static func runLiveProbe() {
        let queue = DispatchQueue(label: "com.ourolabs.ourocode.agent-feed-live-probe")
        let semaphore = DispatchSemaphore(value: 0)
        let feed = OuroborosAgentEventFeed(callbackQueue: queue)
        var received: OuroborosBoardSnapshot?
        feed.onSnapshot = { snapshot in
            guard received == nil else { return }
            received = snapshot
            semaphore.signal()
        }
        queue.sync { feed.synchronize(executionIDs: []) }
        let result = semaphore.wait(timeout: .now() + 10)
        queue.sync { feed.stop() }
        guard result == .success, let received else {
            require(false, "live dashboard SSE did not yield an agent board")
            return
        }
        require(!received.executionID.isEmpty, "live board omitted execution identity")
        require(!received.agents.isEmpty, "live board omitted agent cards")
        print("PASS: live Ouroboros feed \(received.executionID) yielded \(received.agents.count) agents")
    }

}
