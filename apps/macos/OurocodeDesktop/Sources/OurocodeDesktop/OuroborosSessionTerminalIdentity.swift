import Foundation

/// The durable identity of one Ouroboros fanout attempt.  Labels, AC ids and
/// display paths are intentionally absent: retries may reuse any of those
/// values, while this tuple is the only safe join key for a terminal surface.
struct OuroborosSessionAttemptIdentityV1: Equatable, Hashable {
    let sourceID: String
    let sessionID: String
    let executionID: String
    let scopeID: String
    let attemptID: String
}

struct OuroborosPTYSurfaceBindingV1: Equatable {
    let identity: OuroborosSessionAttemptIdentityV1
    let terminalID: String
    let brokerGeneration: UInt64
}

enum OuroborosSessionSurfaceUnboundReasonV1: String, Equatable {
    case notAdvertised
    case malformed
    case unsupportedKind
    case missingTerminalID
    case missingBrokerGeneration
    case invalidBrokerGeneration
}

enum OuroborosSessionSurfaceResolutionV1: Equatable {
    case unbound(OuroborosSessionSurfaceUnboundReasonV1)
    case pty(OuroborosPTYSurfaceBindingV1)
}

enum OuroborosSessionTerminalIdentityDecoderV1 {
    static let maximumIdentifierBytes = 1_024
    static let maximumTerminalIdentifierBytes = 128

    /// Decode the server-owned target identity against the compact row that
    /// requested it. A target with a different execution/session is rejected;
    /// the client never relocates a target by matching a label or AC id.
    static func identity(
        sourceID: String,
        sessionID: String,
        expectedExecutionID: String,
        target: [String: Any]
    ) -> OuroborosSessionAttemptIdentityV1? {
        guard valid(sourceID, maximumBytes: maximumIdentifierBytes),
              valid(sessionID, maximumBytes: maximumIdentifierBytes),
              valid(expectedExecutionID, maximumBytes: maximumIdentifierBytes),
              let executionID = target["execution_id"] as? String,
              executionID == expectedExecutionID,
              valid(executionID, maximumBytes: maximumIdentifierBytes),
              let scopeID = target["target_session_scope_id"] as? String,
              valid(scopeID, maximumBytes: maximumIdentifierBytes),
              let attemptID = target["target_session_attempt_id"] as? String,
              valid(attemptID, maximumBytes: maximumIdentifierBytes) else {
            return nil
        }
        if let rawSessionID = target["session_id"] {
            guard let advertisedSessionID = rawSessionID as? String,
                  advertisedSessionID == sessionID else {
                return nil
            }
        }
        return OuroborosSessionAttemptIdentityV1(
            sourceID: sourceID,
            sessionID: sessionID,
            executionID: executionID,
            scopeID: scopeID,
            attemptID: attemptID
        )
    }

    static func stableTabID(for identity: OuroborosSessionAttemptIdentityV1) -> String {
        framedKey(
            prefix: "attempt",
            components: [
                identity.sourceID,
                identity.sessionID,
                identity.executionID,
                identity.scopeID,
                identity.attemptID,
            ]
        )
    }

    static func stableGroupID(sourceID: String, executionID: String) -> String {
        framedKey(prefix: "execution", components: [sourceID, executionID])
    }

    /// Surface is optional metadata, not action authority. A malformed or
    /// absent surface therefore leaves a usable read-only target unbound.
    /// The broker generation is mandatory whenever a PTY is advertised so a
    /// stale terminal id can never be mistaken for a current surface.
    static func surface(
        target: [String: Any],
        identity: OuroborosSessionAttemptIdentityV1
    ) -> OuroborosSessionSurfaceResolutionV1 {
        guard let raw = target["surface"] else {
            return .unbound(.notAdvertised)
        }
        guard let object = raw as? [String: Any] else {
            return .unbound(.malformed)
        }
        guard let kind = object["kind"] as? String else {
            return .unbound(.malformed)
        }
        guard kind == "pty" else {
            return .unbound(.unsupportedKind)
        }
        guard let terminalID = object["terminal_id"] as? String,
              valid(terminalID, maximumBytes: maximumTerminalIdentifierBytes) else {
            return .unbound(.missingTerminalID)
        }
        guard let number = object["broker_generation"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .unbound(.missingBrokerGeneration)
        }
        let generation = number.uint64Value
        guard generation > 0, NSNumber(value: generation) == number else {
            return .unbound(.invalidBrokerGeneration)
        }
        return .pty(OuroborosPTYSurfaceBindingV1(
            identity: identity,
            terminalID: terminalID,
            brokerGeneration: generation
        ))
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func framedKey(prefix: String, components: [String]) -> String {
        prefix + components.map { ":\($0.utf8.count):\($0)" }.joined()
    }
}
