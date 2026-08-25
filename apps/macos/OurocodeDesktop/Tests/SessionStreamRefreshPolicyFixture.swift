import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionStreamRefreshPolicyFixture {
    static func main() {
        require(SessionStreamRefreshPolicy.interval == 2, "live refresh interval drifted")
        require(
            SessionStreamRefreshPolicy.shouldAutoFollow(
                hadReadyPresentation: false,
                isLive: true,
                wasFollowingLatest: false,
                hasStructuredProjection: true
            ),
            "a newly entered live session did not open at latest activity"
        )
        require(
            !SessionStreamRefreshPolicy.shouldAutoFollow(
                hadReadyPresentation: true,
                isLive: true,
                wasFollowingLatest: false,
                hasStructuredProjection: true
            ),
            "stream refresh stole scroll position from a user reading history"
        )
        require(
            SessionStreamRefreshPolicy.shouldAutoFollow(
                hadReadyPresentation: true,
                isLive: true,
                wasFollowingLatest: true,
                hasStructuredProjection: true
            ),
            "a live-tail reader stopped following new activity"
        )
        require(
            SessionStreamRefreshPolicy.shouldPublish(previous: nil, next: snapshot("one")),
            "first stream snapshot was suppressed"
        )
        let first = snapshot("one")
        require(!SessionStreamRefreshPolicy.shouldPublish(previous: first, next: first), "identical stream snapshots republished")
        require(SessionStreamRefreshPolicy.shouldPublish(previous: first, next: snapshot("two")), "changed stream snapshot was suppressed")
        print("PASS: live session stream refreshes changed snapshots and preserves scroll agency")
    }

    private static func snapshot(_ eventID: String) -> OuroborosSessionDetailProjectionV0511.Snapshot {
        OuroborosSessionDetailProjectionV0511.Snapshot(
            sessionID: "session",
            executionID: "execution",
            attemptFilter: nil,
            events: [
                .init(
                    id: eventID,
                    type: .sessionStarted,
                    timestamp: "2026-08-21T00:00:00Z",
                    aggregateType: "session",
                    aggregateID: "session",
                    summary: eventID
                )
            ],
            moreAvailable: false,
            runProjection: nil
        )
    }
}
