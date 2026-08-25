import Foundation

/// Stable, bounded refresh decisions for one open session workspace. The MCP
/// adapter owns transport polling; the view receives only changed snapshots,
/// matching Maestro's normalized-event lesson without importing its runtime.
enum SessionStreamRefreshPolicy {
    static let interval: TimeInterval = 2
    static let leewayMilliseconds = 200

    static func shouldPublish(
        previous: OuroborosSessionDetailProjectionV0511.Snapshot?,
        next: OuroborosSessionDetailProjectionV0511.Snapshot
    ) -> Bool {
        previous != next
    }

    static func shouldAutoFollow(
        hadReadyPresentation: Bool,
        isLive: Bool,
        wasFollowingLatest: Bool,
        hasStructuredProjection: Bool
    ) -> Bool {
        if !hadReadyPresentation {
            return isLive || !hasStructuredProjection
        }
        return wasFollowingLatest
    }
}
