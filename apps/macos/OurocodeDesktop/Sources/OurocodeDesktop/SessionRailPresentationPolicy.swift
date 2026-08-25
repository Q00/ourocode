import AppKit

enum SessionRailRowRole {
    case source
    case collection
    case sessionGroup
    case sessionLeaf
    case item
}

/// One lifecycle predicate owns every interactive session capability. Cached
/// target or terminal metadata must never outlive the authoritative lifecycle
/// that granted its use.
enum SessionLifecycleCapabilityPolicy {
    static func isLive(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized == "running" || normalized == "active"
    }

    static func permitsInteraction(parentStatus: String, childStatus: String) -> Bool {
        isLive(parentStatus) && isLive(childStatus)
    }

    static func shouldRevokeInteractiveMetadata(authoritativeStatus: String) -> Bool {
        !isLive(authoritativeStatus)
    }
}

/// The rail is a navigator, not a protocol tree. Goose's useful lesson is the
/// separation between recent sessions and the global extension registry. Keep
/// that choice explicit and testable instead of inferring it from whichever
/// outline row happened to be expanded last.
enum SessionRailMode: String, CaseIterable, Equatable {
    case sessions = "Sessions"
    case mcp = "MCP"

    static let initial: SessionRailMode = .mcp
}

enum SessionRailModePresentationPolicy {
    static func headerTitle(for mode: SessionRailMode) -> String { mode.rawValue }

    static func accessibilityHelp(for mode: SessionRailMode) -> String {
        switch mode {
        case .sessions:
            return "Browse Ouroboros fanout sessions."
        case .mcp:
            return "Browse connected MCP sources and their capabilities."
        }
    }
}

/// Polling may replace every outline object, but it must not take navigation
/// agency away from the user by collapsing the live work they opened. Return
/// the stable disclosures that are required to keep live sessions and the
/// selected session path reachable; ordinary history disclosures remain
/// user-controlled.
enum SessionRailExpansionPolicy {
    static func requiredExpansionIDs<Node>(
        roots: [Node],
        selectedNodeID: String?,
        id: (Node) -> String,
        children: (Node) -> [Node],
        isLiveBucket: (Node) -> Bool
    ) -> Set<String> {
        var required = Set<String>()

        func visit(_ node: Node) -> Bool {
            if isLiveBucket(node) { required.insert(id(node)) }
            var containsSelection = id(node) == selectedNodeID
            for child in children(node) {
                containsSelection = visit(child) || containsSelection
            }
            if containsSelection, !children(node).isEmpty {
                required.insert(id(node))
            }
            return containsSelection
        }

        for root in roots { _ = visit(root) }
        return required
    }
}

struct MCPSessionsLinkPresentation: Equatable {
    let title: String
    let detail: String
    let stateLabel: String
    let accessibilityHelp: String
}

/// MCP catalog rows describe protocol capabilities; they are not session
/// destinations. A source that advertises the optional Sessions extension gets
/// one explicit navigation link so the first-run MCP view never strands users
/// on an inert descriptor that merely happens to mention sessions.
enum MCPSessionsLinkPresentationPolicy {
    static func id(sourceID: String) -> String { "link:\(sourceID):sessions" }

    /// Ouroboros also exposes its compact session projection as a standard
    /// MCP resource. Keep that descriptor truthful, but do not strand users
    /// in an inspector when the same source has a typed Sessions adapter.
    /// Matching the exact URI avoids guessing from human-facing titles such
    /// as “sessions”, which remain valid names for unrelated MCP resources.
    static func sessionIndexResourceID(sourceID: String) -> String {
        "\(sourceID):resource:ouroboros://sessions"
    }

    static func matches(nodeID: String, sourceID: String) -> Bool {
        nodeID == id(sourceID: sourceID)
            || nodeID == sessionIndexResourceID(sourceID: sourceID)
    }

    static func resolve(
        hasSessionsExtension: Bool,
        liveCount: Int,
        totalCount: Int
    ) -> MCPSessionsLinkPresentation? {
        guard hasSessionsExtension else { return nil }
        let detail: String
        let stateLabel: String
        let accessibilityHelp: String
        if liveCount > 0 {
            detail = liveCount == 1
                ? "1 active · open its activity or terminal"
                : "\(liveCount) active · choose a session"
            stateLabel = liveCount == 1 ? "Open live session ›" : "Browse sessions ›"
            accessibilityHelp = liveCount == 1
                ? "Click or press Return to open the active session. A terminal opens only when that session provides one."
                : "Click or press Return to browse the active sessions and choose one."
        } else if totalCount > 0 {
            detail = "Recent Ouroboros activity"
            stateLabel = "Browse history ›"
            accessibilityHelp = "Click or press Return to browse recent session history."
        } else {
            detail = "Open the session browser"
            stateLabel = "Browse sessions ›"
            accessibilityHelp = "Click or press Return to open the session browser."
        }
        return MCPSessionsLinkPresentation(
            title: "Sessions",
            detail: detail,
            stateLabel: stateLabel,
            accessibilityHelp: accessibilityHelp
        )
    }
}

enum SessionCrossLinkCandidateKind: Equatable {
    case sessionGroup
    case emptyState
}

struct SessionCrossLinkCandidate: Equatable {
    let id: String
    let sourceID: String
    let status: String
    let kind: SessionCrossLinkCandidateKind
    let ancestorIDs: [String]
}

struct SessionCrossLinkLanding: Equatable {
    let destinationID: String
    let ancestorIDsToExpand: [String]
}

/// A cross-link must stay inside the source that advertised it and must reveal
/// the destination even when the user previously collapsed that source. This
/// pure projection keeps mouse, Return, and accessibility activation on the
/// same deterministic landing contract.
enum SessionCrossLinkLandingPolicy {
    static func resolve(
        preferredSourceID: String,
        candidates: [SessionCrossLinkCandidate]
    ) -> SessionCrossLinkLanding? {
        let scoped = candidates.filter { $0.sourceID == preferredSourceID }
        let liveStatuses = Set(["running", "active"])
        let destination = scoped.first {
            $0.kind == .sessionGroup && liveStatuses.contains($0.status.lowercased())
        } ?? scoped.first {
            $0.kind == .sessionGroup
        } ?? scoped.first {
            $0.kind == .emptyState
        }
        guard let destination else { return nil }
        return SessionCrossLinkLanding(
            destinationID: destination.id,
            ancestorIDsToExpand: destination.ancestorIDs
        )
    }
}

struct SessionCollectionEmptyPresentation: Equatable {
    let title: String
    let detail: String
}

/// Explain an empty Sessions rail instead of rendering a blank outline that
/// looks broken. Session discovery is automatic, so the copy describes state
/// without inventing a button or terminal action.
enum SessionCollectionEmptyPresentationPolicy {
    static func resolve(sourceStatus: String) -> SessionCollectionEmptyPresentation {
        switch sourceStatus.lowercased() {
        case "starting":
            return SessionCollectionEmptyPresentation(
                title: "Finding sessions…",
                detail: "Checking Ouroboros for active and recent runs."
            )
        case "limited", "offline":
            return SessionCollectionEmptyPresentation(
                title: "Sessions unavailable",
                detail: "Ourocode will retry while Sessions is open."
            )
        default:
            return SessionCollectionEmptyPresentation(
                title: "No sessions yet",
                detail: "Agent runs appear here automatically when Ouroboros starts them."
            )
        }
    }
}

/// A session row has two independent capabilities: a terminal surface may be
/// openable even when steering is unavailable, and a completed run may still
/// be useful as history even though it cannot be re-attached. Keep that
/// distinction in a small, testable policy so the rail never makes a dead
/// session look like a live terminal.
enum SessionTerminalEntryPresentation: Equatable {
    case none
    /// Open the existing session detail/control surface without claiming that
    /// a PTY or steering authority exists.
    case openSession(readOnly: Bool)
    case openSingle
    /// A live headless fanout has useful exact attempts even when none owns a
    /// PTY. Make those attempts a first-class destination instead of hiding
    /// them behind the outline disclosure triangle.
    case revealAgents(Int)
    case revealRuns(Int)
    case readOnlyHistory
    case attachmentUnavailable(String)

    var summary: String {
        switch self {
        case .none: return "No live terminal"
        case .openSession(let readOnly): return readOnly ? "Review history" : "Steer session"
        case .openSingle: return "Open terminal"
        case .revealAgents(let count): return count > 0 ? "\(count) agents" : "Find agents"
        case .revealRuns(let count): return "\(count) terminals"
        case .readOnlyHistory: return "Run ended"
        case .attachmentUnavailable(let reason): return reason
        }
    }
}

enum SessionTerminalEntryPolicy {
    static func resolve(
        isGroup: Bool,
        isProjectionTrusted: Bool,
        advertisedTerminalCount: Int,
        isCompleted: Bool
    ) -> SessionTerminalEntryPresentation {
        guard isProjectionTrusted else { return .none }
        guard !isCompleted else { return .openSession(readOnly: true) }
        if advertisedTerminalCount == 1 { return .openSingle }
        if advertisedTerminalCount > 1 {
            return isGroup ? .revealRuns(advertisedTerminalCount) : .none
        }
        return .openSession(readOnly: false)
    }
}

/// Headless fanout attempts are still enterable session destinations. Keep
/// their navigation policy independent from PTY count so a missing terminal
/// can never make the exact agent rows disappear from the common path.
enum SessionAgentEntryPolicy {
    static func resolve(
        isGroup: Bool,
        isProjectionTrusted: Bool,
        isCompleted: Bool,
        advertisedTerminalCount: Int,
        exactAgentCount: Int
    ) -> SessionTerminalEntryPresentation? {
        guard isGroup,
              isProjectionTrusted,
              !isCompleted,
              advertisedTerminalCount == 0 else { return nil }
        return .revealAgents(max(0, exactAgentCount))
    }
}

/// Target discovery can finish after the user has opened a session workspace.
/// Treat that refresh as presentation-only: `Open` means activity, while a
/// later `Terminal` or `Choose` affordance requires a second explicit action.
/// Discovery must never reinterpret the earlier click as terminal authority.
enum SessionTerminalActivationIntentResolution: Equatable {
    case none
    case wait
    case activate
    case revealRuns
}

enum MCPSessionTargetDiscoveryOutcome: Equatable {
    case discovered(Int)
    case empty
    case unavailable(String)
}

struct MCPSessionTargetDiscoveryResult: Equatable {
    let executionID: String
    let intentGeneration: UInt64?
    let outcome: MCPSessionTargetDiscoveryOutcome
}

enum SessionTargetDiscoveryIntentPolicy {
    static func accepts(
        _ result: MCPSessionTargetDiscoveryResult,
        pendingExecutionID: String?,
        pendingGeneration: UInt64?,
        selectionStillMatches: Bool
    ) -> Bool {
        selectionStillMatches
            && result.intentGeneration != nil
            && result.executionID == pendingExecutionID
            && result.intentGeneration == pendingGeneration
    }
}

enum SessionTerminalActivationIntentPolicy {
    static func shouldArm(
        isGroup: Bool,
        status: String,
        entry: SessionTerminalEntryPresentation
    ) -> Bool {
        // Keep the arguments in the policy boundary so callers cannot bypass
        // it by inferring intent from one field. There is deliberately no
        // state in which an Activity/History click arms terminal activation.
        _ = isGroup
        _ = status
        _ = entry
        return false
    }

    static func resolve(
        hasPendingIntent: Bool,
        selectionMatchesIntent: Bool,
        entry: SessionTerminalEntryPresentation
    ) -> SessionTerminalActivationIntentResolution {
        guard hasPendingIntent, selectionMatchesIntent else { return .none }
        switch entry {
        case .none: return .wait
        case .openSession, .revealAgents: return .none
        case .openSingle: return .activate
        case .revealRuns: return .revealRuns
        case .readOnlyHistory, .attachmentUnavailable: return .none
        }
    }
}

/// A session group is only a display container; steering authority belongs to
/// one exact attempt. Promote a group click only when that destination is
/// unambiguous, live, and still backed by a trusted projection.
enum SessionGroupPrimaryAttemptPolicy {
    static func soleSteerableIndex(
        entry: SessionTerminalEntryPresentation,
        isGroup: Bool,
        status: String,
        isProjectionTrusted: Bool,
        steerableChildren: [Bool]
    ) -> Int? {
        let normalizedStatus = status.lowercased()
        guard entry == .openSession(readOnly: false),
              isGroup,
              isProjectionTrusted,
              normalizedStatus == "running" || normalizedStatus == "active" else {
            return nil
        }
        let matches = steerableChildren.indices.filter { steerableChildren[$0] }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct SessionTerminalEntryAffordance: Equatable {
    let destination: SessionPrimaryDestination
    let stateLabel: String?
    let accessibilityHelp: String?
    let isPrimaryAction: Bool
}

/// The destination behind a session row's primary action. This is deliberately
/// separate from steering capability: a headless attempt can open useful
/// activity and accept an authenticated next-turn message without owning a
/// PTY, while only a verified broker surface may advertise Terminal.
enum SessionPrimaryDestination: Equatable {
    case none
    case activity(readOnly: Bool)
    case terminal
    case agentPicker(Int)
    case terminalPicker(Int)
}

enum SessionTerminalEntryAffordancePolicy {
    static func resolve(
        entry: SessionTerminalEntryPresentation,
        isGroup: Bool,
        status: String,
        isProjectionTrusted: Bool
    ) -> SessionTerminalEntryAffordance {
        guard isProjectionTrusted else {
            return SessionTerminalEntryAffordance(
                destination: .none,
                stateLabel: nil,
                accessibilityHelp: nil,
                isPrimaryAction: false
            )
        }
        switch entry {
        case .openSession(let readOnly):
            return SessionTerminalEntryAffordance(
                destination: .activity(readOnly: readOnly),
                stateLabel: readOnly ? "View history ›" : "Open live session ›",
                accessibilityHelp: readOnly
                    ? "Click or press Return to enter this session and review its read-only history."
                    : "Click or press Return to enter this live streaming session. Messages and terminal entry remain scoped to exact agents inside it.",
                isPrimaryAction: true
            )
        case .openSingle:
            if isGroup {
                return SessionTerminalEntryAffordance(
                    destination: .activity(readOnly: false),
                    stateLabel: "Open live session ›",
                    accessibilityHelp: "Click or press Return to enter this live streaming session. Its verified terminal is available inside the session workspace.",
                    isPrimaryAction: true
                )
            }
            return SessionTerminalEntryAffordance(
                destination: .terminal,
                stateLabel: "Open terminal ›",
                accessibilityHelp: "Click or press Return to open this terminal. Press Space for session details.",
                isPrimaryAction: true
            )
        case .revealAgents(let count):
            return SessionTerminalEntryAffordance(
                destination: .agentPicker(count),
                stateLabel: "Open live session ›",
                accessibilityHelp: "Click or press Return to enter this live streaming session and message its exact agents independently.",
                isPrimaryAction: true
            )
        case .revealRuns:
            return SessionTerminalEntryAffordance(
                destination: .activity(readOnly: false),
                stateLabel: "Open live session ›",
                accessibilityHelp: "Click or press Return to enter this live streaming session and choose an exact terminal from inside it.",
                isPrimaryAction: true
            )
        case .readOnlyHistory:
            return SessionTerminalEntryAffordance(
                destination: .activity(readOnly: true),
                stateLabel: isGroup ? "History" : "Ended",
                accessibilityHelp: "This run has ended and has no live terminal. Press Space to review its history.",
                isPrimaryAction: false
            )
        case .attachmentUnavailable(let reason):
            return SessionTerminalEntryAffordance(
                destination: .none,
                stateLabel: "Unavailable",
                accessibilityHelp: "\(reason). Press Space to review session details.",
                isPrimaryAction: false
            )
        case .none:
            return SessionTerminalEntryAffordance(
                destination: .none,
                stateLabel: nil,
                accessibilityHelp: nil,
                isPrimaryAction: false
            )
        }
    }
}

struct SessionRailRowPresentation: Equatable {
    let height: CGFloat
    let usesTwoLines: Bool
    let titleTruncation: NSLineBreakMode
}

enum SessionRailPresentationPolicy {
    static func row(_ role: SessionRailRowRole, emptySessionsCollection: Bool = false) -> SessionRailRowPresentation {
        switch role {
        case .source:
            return SessionRailRowPresentation(height: 42, usesTwoLines: false, titleTruncation: .byTruncatingTail)
        case .collection:
            return SessionRailRowPresentation(
                height: emptySessionsCollection ? 50 : 38,
                usesTwoLines: emptySessionsCollection,
                titleTruncation: .byTruncatingTail
            )
        case .sessionGroup:
            return SessionRailRowPresentation(height: 52, usesTwoLines: true, titleTruncation: .byTruncatingMiddle)
        case .sessionLeaf:
            return SessionRailRowPresentation(height: 50, usesTwoLines: true, titleTruncation: .byTruncatingMiddle)
        case .item:
            return SessionRailRowPresentation(height: 42, usesTwoLines: false, titleTruncation: .byTruncatingMiddle)
        }
    }

    static func configureTextPriority(title: NSTextField, state: NSTextField) {
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)
    }

    static func configureTooltips(
        title: NSTextField,
        detail: NSTextField,
        fullTitle: String,
        fullDetail: String
    ) {
        title.toolTip = fullTitle
        detail.toolTip = fullDetail
    }
}

enum SessionComposerPresentation: Equatable {
    case hidden
    case passiveReadOnly
    case verifiedComposer

    var height: CGFloat {
        switch self {
        case .hidden: 0
        case .passiveReadOnly: 32
        case .verifiedComposer: 124
        }
    }
}

enum SessionComposerPresentationPolicy {
    static func resolve(
        hasSessionSelection: Bool,
        hasVerifiedAuthority: Bool,
        hasExactTarget: Bool = true
    ) -> SessionComposerPresentation {
        guard hasSessionSelection else { return .hidden }
        return hasVerifiedAuthority && hasExactTarget ? .verifiedComposer : .passiveReadOnly
    }

    static func passiveStatus(
        hasDraft: Bool,
        authorityExplanation: String,
        terminalStatus: String? = nil
    ) -> String {
        if let terminalStatus, !terminalStatus.isEmpty {
            return "\(terminalStatus) · Steering unavailable"
        }
        if hasDraft {
            return "Draft saved · Steering unavailable"
        }
        return "Steering unavailable"
    }

    static func passiveStatusHelp(
        hasDraft: Bool,
        authorityExplanation: String,
        terminalStatus: String? = nil
    ) -> String {
        let explanation = authorityExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = explanation.lowercased().hasPrefix("read-only")
            ? explanation
            : "Read-only · \(explanation)"
        let status = terminalStatus.map { "Terminal: \($0)." }
        if hasDraft {
            return (["Draft saved.", status, normalized].compactMap { $0 }).joined(separator: " ")
        }
        return ([status, normalized].compactMap { $0 }).joined(separator: " ")
    }
}

struct SessionSteeringDraftIdentity: Equatable {
    let executionID: String
    let scopeID: String
    let attemptID: String
}

/// Drafts and delivery receipts must move from session identity to exact
/// attempt identity at the same moment as the composer. Keeping this policy
/// free of transport types makes the equality contract independently testable.
enum SessionSteeringDraftKeyPolicy {
    static func key(
        sourceID: String,
        sessionID: String,
        executionID: String,
        exactAttempt: SessionSteeringDraftIdentity?
    ) -> String {
        guard let exactAttempt else {
            return framedKey(prefix: "group", values: [sourceID, sessionID, executionID])
        }
        return exactKey(
            sourceID: sourceID,
            sessionID: sessionID,
            executionID: exactAttempt.executionID,
            scopeID: exactAttempt.scopeID,
            attemptID: exactAttempt.attemptID
        )
    }

    static func exactKey(
        sourceID: String,
        sessionID: String,
        executionID: String,
        scopeID: String,
        attemptID: String
    ) -> String {
        framedKey(
            prefix: "attempt",
            values: [sourceID, sessionID, executionID, scopeID, attemptID]
        )
    }

    private static func framedKey(prefix: String, values: [String]) -> String {
        prefix + values.map { ":\($0.utf8.count):\($0)" }.joined()
    }
}

/// AppKit only sends an expand notification for rows its data source marks as
/// expandable. A live fanout starts with no exact attempts, so child count
/// alone would make the very action that discovers those attempts impossible.
enum SessionRailExpandablePolicy {
    static func resolve(
        hasChildren: Bool,
        isLazyCatalogCollection: Bool,
        isSessionGroup: Bool,
        isProjectionTrusted: Bool,
        isLive: Bool,
        hasExecutionIdentity: Bool,
        hasSessionAdapter: Bool
    ) -> Bool {
        if hasChildren || isLazyCatalogCollection { return true }
        return isSessionGroup
            && isProjectionTrusted
            && isLive
            && hasExecutionIdentity
            && hasSessionAdapter
    }
}
