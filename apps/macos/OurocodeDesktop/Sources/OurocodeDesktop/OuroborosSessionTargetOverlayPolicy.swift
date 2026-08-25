import Foundation

/// Revokes every field obtained from one target-discovery response as a single
/// externally published snapshot. A stale identity is authority just as much
/// as a stale PTY surface: neither may survive an empty, malformed, failed, or
/// superseded discovery generation.
enum OuroborosSessionTargetOverlayPolicy {
    @discardableResult
    static func revoke<Target>(
        target: inout Target?,
        identity: inout OuroborosSessionAttemptIdentityV1?,
        surface: inout OuroborosSessionSurfaceResolutionV1
    ) -> Bool {
        let changed = target != nil
            || identity != nil
            || surface != .unbound(.notAdvertised)
        target = nil
        identity = nil
        surface = .unbound(.notAdvertised)
        return changed
    }
}

enum OuroborosSessionTargetSnapshotError: Error, Equatable {
    case conflictingDuplicateIdentity
}

/// Reconciles one bounded discovery response before it reaches the session
/// projection. The first occurrence wins ordering; an identical repeated
/// payload collapses, while a second payload for the same exact identity is
/// rejected instead of guessing which attempt is authoritative.
enum OuroborosSessionTargetSnapshotPolicy {
    static func isDiscoveredAttemptID(_ id: String) -> Bool {
        id.hasPrefix("attempt:")
    }

    static func deduplicated<Identity: Hashable, Target: Equatable>(
        _ values: [(identity: Identity, target: Target)]
    ) -> Result<[Target], OuroborosSessionTargetSnapshotError> {
        var seen: [Identity: Target] = [:]
        var ordered: [Target] = []
        ordered.reserveCapacity(values.count)
        for value in values {
            if let existing = seen[value.identity] {
                guard existing == value.target else {
                    return .failure(.conflictingDuplicateIdentity)
                }
                continue
            }
            seen[value.identity] = value.target
            ordered.append(value.target)
        }
        return .success(ordered)
    }
}

/// Keeps a user-opened multiplexer actionable while the independent compact
/// session index is polling. The exact target snapshot is replaced only by
/// the next target-discovery response (or by an authoritative lifecycle
/// revocation); an unrelated metadata refresh must not erase the controls the
/// user is currently typing into.
enum OuroborosActiveTargetRefreshPolicy {
    static func preservesSnapshot(
        executionID: String,
        activeExecutionID: String?
    ) -> Bool {
        executionID == activeExecutionID
    }

    static func shouldRevalidate(
        executionID: String,
        activeExecutionID: String?,
        sessionIsLive: Bool
    ) -> Bool {
        sessionIsLive && executionID == activeExecutionID
    }
}
