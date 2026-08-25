struct MCPSessionActivation: Equatable {
    let sourceID: String
    let sessionID: String
    let executionID: String
    let scopeID: String?
    let attemptID: String?
    /// A leaf is never allowed to degrade into the group query when its exact
    /// identity is absent or malformed.
    let requiresExactAttempt: Bool
    let generation: UInt64

    var attemptFilter: OuroborosSessionDetailProjectionV0511.AttemptFilter? {
        guard requiresExactAttempt, let scopeID, let attemptID else { return nil }
        return OuroborosSessionDetailProjectionV0511.attemptFilter(
            executionID: executionID,
            scopeID: scopeID,
            attemptID: attemptID
        )
    }
}
