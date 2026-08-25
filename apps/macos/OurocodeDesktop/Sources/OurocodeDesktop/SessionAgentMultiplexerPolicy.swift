/// Pure presentation contract for the headless-agent work plane. It is kept
/// independent from AppKit and MCP transport types so identity, capacity, and
/// honesty rules can be fixture-tested without launching the app.
struct SessionAgentMultiplexerCandidate: Equatable {
    let id: String
    let title: String
    let status: String
    let summary: String
    let executionID: String
    let scopeID: String
    let attemptID: String
    let hasPTY: Bool
    /// A verified live broker binding exists for this exact attempt. Terminal
    /// entry is independent from MCP after-turn steering authority.
    let canEnterTerminal: Bool
    let canSteer: Bool
    let draft: String
    let receipt: String
    let unavailableReason: String
}

enum SessionAgentPrimaryAction: Equatable {
    case enterTerminal
    case messageAgent
    case none

    var label: String {
        switch self {
        case .enterTerminal: "Enter Terminal"
        case .messageAgent: "Message Agent"
        case .none: "Unavailable"
        }
    }
}

struct SessionAgentCardPresentation: Equatable {
    let id: String
    let title: String
    let status: String
    let summary: String
    let exactIdentity: String
    let surfaceLabel: String
    let primaryAction: SessionAgentPrimaryAction
    let canEnterTerminal: Bool
    let canSteer: Bool
    let draft: String
    let receipt: String
    let steeringHelp: String
}

struct SessionAgentMultiplexerPresentation: Equatable {
    static let hidden = SessionAgentMultiplexerPresentation(
        cards: [],
        overflowCount: 0
    )

    let cards: [SessionAgentCardPresentation]
    let overflowCount: Int

    var isVisible: Bool { !cards.isEmpty }
    var countLabel: String {
        overflowCount > 0
            ? "Agents · \(cards.count) shown · \(overflowCount) more"
            : "Agents · \(cards.count)"
    }
}

enum SessionAgentMultiplexerPolicy {
    static let capacity = 4
    static let twoColumnMinimumWidth = 620.0

    static func columnCount(availableWidth: Double) -> Int {
        availableWidth >= twoColumnMinimumWidth ? 2 : 1
    }

    /// A card activation is valid only inside the exact group/detail context
    /// that produced it. The caller separately rechecks the full attempt and
    /// PTY identities; this gate makes selection/reload races explicit and
    /// fixture-testable.
    static func terminalActivationIsCurrent(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        expectedGroupID: String,
        selectedGroupID: String?,
        expectedChildID: String,
        currentChildID: String?,
        detailWorkspaceVisible: Bool,
        exactIdentityStillMatches: Bool
    ) -> Bool {
        expectedGeneration == currentGeneration
            && !expectedGroupID.isEmpty
            && expectedGroupID == selectedGroupID
            && !expectedChildID.isEmpty
            && expectedChildID == currentChildID
            && detailWorkspaceVisible
            && exactIdentityStillMatches
    }

    static func resolve(
        _ candidates: [SessionAgentMultiplexerCandidate]
    ) -> SessionAgentMultiplexerPresentation {
        var seenIDs = Set<String>()
        var seenIdentities = Set<String>()
        let exact = candidates.filter { candidate in
            let framedIdentity = [
                candidate.executionID,
                candidate.scopeID,
                candidate.attemptID,
            ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            guard !candidate.id.isEmpty,
                  !candidate.executionID.isEmpty,
                  !candidate.scopeID.isEmpty,
                  !candidate.attemptID.isEmpty,
                  seenIDs.insert(candidate.id).inserted,
                  seenIdentities.insert(framedIdentity).inserted else { return false }
            return true
        }
        let cards = exact.prefix(capacity).map { candidate in
            let surface = candidate.hasPTY
                ? (candidate.canEnterTerminal
                    ? "Terminal ready"
                    : "Terminal unavailable")
                : "Messages"
            let primaryAction: SessionAgentPrimaryAction = candidate.canEnterTerminal
                ? .enterTerminal
                : (candidate.canSteer ? .messageAgent : .none)
            let help: String
            switch primaryAction {
            case .enterTerminal:
                help = "Open the exact broker terminal for this agent and send keyboard input there."
            case .messageAgent:
                help = "Focus the message field for this exact agent. Queue sends after its current turn."
            case .none:
                help = candidate.unavailableReason
            }
            return SessionAgentCardPresentation(
                id: candidate.id,
                title: candidate.title,
                status: candidate.status,
                summary: candidate.summary,
                exactIdentity: "execution \(candidate.executionID) · scope \(candidate.scopeID) · attempt \(candidate.attemptID)",
                surfaceLabel: surface,
                primaryAction: primaryAction,
                canEnterTerminal: candidate.canEnterTerminal,
                canSteer: candidate.canSteer,
                draft: candidate.draft,
                receipt: candidate.receipt,
                steeringHelp: help
            )
        }
        return SessionAgentMultiplexerPresentation(
            cards: Array(cards),
            overflowCount: max(0, exact.count - capacity)
        )
    }
}
