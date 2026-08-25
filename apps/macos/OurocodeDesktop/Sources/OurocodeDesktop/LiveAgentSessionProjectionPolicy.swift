import Foundation

struct LiveAgentSessionProjection: Equatable {
    let id: String
    let title: String
    let detail: String
    let status: String
    let terminals: [LiveTerminalSession]
}

enum LiveAgentSessionProjectionPolicy {
    /// Projects terminal surfaces into provider-owned agent groups.
    ///
    /// A shared Ouroboros session ID is not a parent relationship: one
    /// execution can contain independent attempts, and OMP parent/child
    /// sessions always have distinct session IDs. Grouping therefore requires
    /// an explicit `parentAgentID` supplied by the provider. Missing, stale,
    /// or cyclic parent references fail closed by leaving the surface at the
    /// nearest independently addressable root.
    static func resolve(_ terminals: [LiveTerminalSession]) -> [LiveAgentSessionProjection] {
        var result: [LiveAgentSessionProjection] = []
        var grouped: [String: [LiveTerminalSession]] = [:]
        var order: [String] = []

        let bound = terminals.compactMap { terminal -> (String, LiveTerminalSession)? in
            guard let binding = terminal.binding else { return nil }
            return (binding.agentID, terminal)
        }
        let byID = Dictionary(uniqueKeysWithValues: bound)

        for terminal in terminals {
            guard let binding = terminal.binding else {
                result.append(singleton(terminal))
                continue
            }
            let rootID = rootID(for: binding.agentID, byID: byID)
            if grouped[rootID] == nil { order.append(rootID) }
            grouped[rootID, default: []].append(terminal)
        }

        for rootID in order {
            guard let members = grouped[rootID], !members.isEmpty else { continue }
            result.append(projection(rootID: rootID, terminals: members))
        }
        return result
    }

    private static func singleton(_ terminal: LiveTerminalSession) -> LiveAgentSessionProjection {
        LiveAgentSessionProjection(
            id: "terminal:\(terminal.id.uuidString)",
            title: terminal.title,
            detail: terminal.detail,
            status: terminal.status,
            terminals: [terminal]
        )
    }

    private static func rootID(
        for id: String,
        byID: [String: LiveTerminalSession]
    ) -> String {
        var cursor = id
        var visited = Set<String>()
        while let terminal = byID[cursor],
              let parentID = terminal.binding?.parentAgentID {
            guard visited.insert(cursor).inserted,
                  parentID != cursor else { return id }
            guard byID[parentID] != nil else { return cursor }
            cursor = parentID
        }
        return cursor
    }

    private static func projection(
        rootID: String,
        terminals: [LiveTerminalSession]
    ) -> LiveAgentSessionProjection {
        let ordered = terminals.sorted {
            let lhsDepth = $0.binding?.depth ?? Int.max
            let rhsDepth = $1.binding?.depth ?? Int.max
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let root = ordered.first
        let activeCount = ordered.filter { $0.status == "active" }.count
        let title = ordered.count > 1
            ? (root.map { "\($0.title) · Session" } ?? "Agent Session")
            : (root?.title ?? "Agent Session")
        return LiveAgentSessionProjection(
            id: "agent:\(rootID)",
            title: title,
            detail: "\(ordered.count) agents · \(activeCount) active",
            status: activeCount > 0 ? "active" : "ready",
            terminals: ordered
        )
    }
}

