struct SessionWorkspaceExecution: Equatable {
    let sessionID: String
    let executionID: String
    let status: String
    let sortKey: String
    let agentIDs: [String]
}

struct SessionWorkspaceProjection: Equatable {
    let sessionID: String
    let executionIDs: [String]
    let status: String
    let sortKey: String
    let agentIDs: [String]
}

enum SessionWorkspaceProjectionPolicy {
    static func resolve(_ executions: [SessionWorkspaceExecution]) -> [SessionWorkspaceProjection] {
        Dictionary(grouping: executions.filter {
            !$0.sessionID.isEmpty && !$0.executionID.isEmpty
        }, by: \.sessionID)
            .values
            .compactMap { values in
                let sorted = values.sorted {
                    if $0.sortKey != $1.sortKey { return $0.sortKey > $1.sortKey }
                    return $0.executionID < $1.executionID
                }
                guard let primary = sorted.first else { return nil }
                var seenAgents = Set<String>()
                let agentIDs = sorted.flatMap(\.agentIDs).filter {
                    !$0.isEmpty && seenAgents.insert($0).inserted
                }
                let live = sorted.contains {
                    let status = $0.status.lowercased()
                    return status == "running" || status == "active"
                }
                return SessionWorkspaceProjection(
                    sessionID: primary.sessionID,
                    executionIDs: sorted.map(\.executionID),
                    status: live ? "running" : primary.status,
                    sortKey: primary.sortKey,
                    agentIDs: agentIDs
                )
            }
            .sorted {
                if $0.sortKey != $1.sortKey { return $0.sortKey > $1.sortKey }
                return $0.sessionID < $1.sessionID
            }
    }
}
