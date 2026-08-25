import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private struct Payload: Equatable {
    let label: String
    let surface: String
}

@main
private enum OuroborosSessionTargetSnapshotFixture {
    static func main() {
        let first = (identity: "attempt-a", target: Payload(label: "Agent A", surface: "pty-1"))
        let duplicate = (identity: "attempt-a", target: Payload(label: "Agent A", surface: "pty-1"))
        let second = (identity: "attempt-b", target: Payload(label: "Agent B", surface: "pty-2"))
        let collapsed = OuroborosSessionTargetSnapshotPolicy.deduplicated([
            first, duplicate, second,
        ])
        require(
            collapsed == .success([first.target, second.target]),
            "identical exact-target duplicates were not collapsed in first-seen order"
        )

        let conflicting = OuroborosSessionTargetSnapshotPolicy.deduplicated([
            first,
            (identity: "attempt-a", target: Payload(label: "Imposter", surface: "pty-9")),
        ])
        require(
            conflicting == .failure(.conflictingDuplicateIdentity),
            "conflicting duplicate payload was not rejected fail-closed"
        )

        require(
            OuroborosSessionTargetSnapshotPolicy.isDiscoveredAttemptID("attempt:9:scope:1")
                && !OuroborosSessionTargetSnapshotPolicy.isDiscoveredAttemptID("AC-1"),
            "base and discovered tab identity boundary drifted"
        )

        require(
            OuroborosActiveTargetRefreshPolicy.preservesSnapshot(
                executionID: "exec-open",
                activeExecutionID: "exec-open"
            ),
            "metadata polling erased the user-opened multiplexer snapshot"
        )
        require(
            !OuroborosActiveTargetRefreshPolicy.preservesSnapshot(
                executionID: "exec-other",
                activeExecutionID: "exec-open"
            ),
            "background session retained stale exact-target authority"
        )
        require(
            OuroborosActiveTargetRefreshPolicy.shouldRevalidate(
                executionID: "exec-open",
                activeExecutionID: "exec-open",
                sessionIsLive: true
            ) && !OuroborosActiveTargetRefreshPolicy.shouldRevalidate(
                executionID: "exec-open",
                activeExecutionID: "exec-open",
                sessionIsLive: false
            ),
            "active target revalidation ignored authoritative lifecycle"
        )
        print("PASS: target snapshots collapse identical attempts and reject conflicting identities")
    }
}
