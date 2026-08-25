struct LiveTerminalSessionTreeNode: Equatable {
    let terminal: LiveTerminalSession
    let children: [LiveTerminalSessionTreeNode]
}

enum LiveTerminalSessionTreePolicy {
    static func resolve(_ terminals: [LiveTerminalSession]) -> [LiveTerminalSessionTreeNode] {
        let boundByAgentID = Dictionary(uniqueKeysWithValues: terminals.compactMap { terminal in
            terminal.binding.map { ($0.agentID, terminal) }
        })
        var childrenByParent: [String: [LiveTerminalSession]] = [:]
        var roots: [LiveTerminalSession] = []
        for terminal in terminals {
            guard let binding = terminal.binding,
                  let parentID = binding.parentAgentID,
                  boundByAgentID[parentID] != nil else {
                roots.append(terminal)
                continue
            }
            childrenByParent[parentID, default: []].append(terminal)
        }

        func makeNode(_ terminal: LiveTerminalSession) -> LiveTerminalSessionTreeNode {
            let agentID = terminal.binding?.agentID
            let children = agentID.flatMap { childrenByParent[$0] } ?? []
            return LiveTerminalSessionTreeNode(
                terminal: terminal,
                children: children.map(makeNode)
            )
        }

        return roots.map(makeNode)
    }
}
