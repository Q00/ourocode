import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func payload(
    instanceID: UUID,
    nonce: String,
    nodes: [[String: Any]]
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "version": 1,
        "provider_id": "omp",
        "instance_id": instanceID.uuidString,
        "nonce": nonce,
        "generation": "process-1",
        "revision": 3,
        "process_id": 42,
        "updated_at_ms": 100,
        "nodes": nodes,
    ], options: [.sortedKeys])
}

private func node(
    id: String,
    parentID: String?,
    kind: String,
    sessionID: String?
) -> [String: Any] {
    [
        "id": id,
        "parent_id": parentID ?? NSNull(),
        "kind": kind,
        "title": id,
        "status": "running",
        "summary": "working",
        "session_id": sessionID ?? NSNull(),
        "created_at_ms": 1,
        "last_activity_ms": 2,
        "capabilities": kind == "main" ? ["terminal"] : ["transcript"],
    ]
}

@main
private enum AgentSessionGraphFixture {
    static func main() {
        let instanceID = UUID()
        let nonce = "nonce-a"
        let valid = AgentSessionGraphSnapshotDecoder.decode(
            payload(instanceID: instanceID, nonce: nonce, nodes: [
                node(id: "Main", parentID: nil, kind: "main", sessionID: "parent-session"),
                node(id: "Explore", parentID: "Main", kind: "sub", sessionID: "child-session"),
                node(id: "Nested", parentID: "Explore", kind: "sub", sessionID: "nested-session"),
            ]),
            expectedInstanceID: instanceID,
            expectedNonce: nonce
        )
        guard case .success(let snapshot) = valid else {
            require(false, "valid explicit parent graph was rejected")
            return
        }
        require(snapshot.nodes.compactMap(\.sessionID) == [
            "parent-session", "child-session", "nested-session",
        ], "separate parent/child session IDs were collapsed")
        require(snapshot.nodes[2].parentID == "Explore", "nested explicit lineage was lost")
        require(snapshot.nodes[1].capabilities == Set(["transcript"]), "capability projection drifted")

        let missingParent = AgentSessionGraphSnapshotDecoder.decode(
            payload(instanceID: instanceID, nonce: nonce, nodes: [
                node(id: "Main", parentID: nil, kind: "main", sessionID: nil),
                node(id: "Child", parentID: "missing", kind: "sub", sessionID: nil),
            ]),
            expectedInstanceID: instanceID,
            expectedNonce: nonce
        )
        require(missingParent == .failure(.missingParent), "missing parent did not fail closed")

        let cycle = AgentSessionGraphSnapshotDecoder.decode(
            payload(instanceID: instanceID, nonce: nonce, nodes: [
                node(id: "Main", parentID: nil, kind: "main", sessionID: nil),
                node(id: "A", parentID: "B", kind: "sub", sessionID: nil),
                node(id: "B", parentID: "A", kind: "sub", sessionID: nil),
            ]),
            expectedInstanceID: instanceID,
            expectedNonce: nonce
        )
        require(cycle == .failure(.cycle), "cyclic lineage did not fail closed")

        let staleIdentity = AgentSessionGraphSnapshotDecoder.decode(
            payload(instanceID: instanceID, nonce: nonce, nodes: [
                node(id: "Main", parentID: nil, kind: "main", sessionID: nil),
            ]),
            expectedInstanceID: UUID(),
            expectedNonce: nonce
        )
        require(staleIdentity == .failure(.identityMismatch), "stale instance identity was accepted")
        print("PASS: provider-neutral agent graph validates explicit lineage and capabilities")
    }
}
