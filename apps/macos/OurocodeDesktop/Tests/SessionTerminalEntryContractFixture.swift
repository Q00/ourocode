import AppKit
import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionTerminalEntryContractFixture {
    static func main() {
        require(SessionLifecycleCapabilityPolicy.isLive("running"), "running lifecycle was not live")
        require(SessionLifecycleCapabilityPolicy.isLive("ACTIVE"), "active lifecycle normalization failed")
        for ended in ["completed", "failed", "cancelled", "canceled", "aborted", "unknown", "checking"] {
            require(
                SessionLifecycleCapabilityPolicy.shouldRevokeInteractiveMetadata(
                    authoritativeStatus: ended
                ),
                "\(ended) lifecycle retained stale steering or terminal metadata"
            )
            require(
                !SessionLifecycleCapabilityPolicy.permitsInteraction(
                    parentStatus: ended,
                    childStatus: "running"
                ),
                "\(ended) parent admitted a stale live child"
            )
        }
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 1,
                isCompleted: false
            ) == .openSingle,
            "one live verified PTY should open directly"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 3,
                isCompleted: false
            ) == .revealRuns(3),
            "multiple live verified PTYs should reveal their agent runs"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 1,
                isCompleted: true
            ) == .openSession(readOnly: true),
            "a completed run must open history without reopening a stale advertised PTY"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: false,
                isProjectionTrusted: true,
                advertisedTerminalCount: 0,
                isCompleted: true
            ) == .openSession(readOnly: true),
            "an ended unbound leaf should open its read-only history"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 0,
                isCompleted: false
            ) == .openSession(readOnly: false),
            "a live headless session became unenterable without a PTY"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: false,
                isProjectionTrusted: true,
                advertisedTerminalCount: 2,
                isCompleted: false
            ) == .none,
            "one leaf must never fan out to multiple terminal surfaces"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: false,
                advertisedTerminalCount: 1,
                isCompleted: false
            ) == .none,
            "unverified MCP projection must not expose terminal entry"
        )
        require(
            SessionAgentEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                isCompleted: false,
                advertisedTerminalCount: 0,
                exactAgentCount: 4
            ) == .revealAgents(4),
            "live headless fanout did not expose its exact agents"
        )
        require(
            SessionAgentEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                isCompleted: false,
                advertisedTerminalCount: 0,
                exactAgentCount: 0
            ) == .revealAgents(0),
            "lazy headless fanout had no discovery action"
        )
        require(
            SessionAgentEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                isCompleted: true,
                advertisedTerminalCount: 0,
                exactAgentCount: 4
            ) == nil,
            "completed fanout exposed stale live agents"
        )
        let exactDraftIdentity = SessionSteeringDraftIdentity(
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1"
        )
        let selectedDraftKey = SessionSteeringDraftKeyPolicy.key(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            exactAttempt: exactDraftIdentity
        )
        let deliveryDraftKey = SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1"
        )
        require(
            selectedDraftKey == deliveryDraftKey,
            "exact-attempt selection and steering delivery used different receipt keys"
        )
        let siblingDraftKey = SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: "ouroboros",
            sessionID: "session-1",
            executionID: "execution-1",
            scopeID: "scope-2",
            attemptID: "attempt-2"
        )
        require(selectedDraftKey != siblingDraftKey, "read-only sibling attempts shared one draft")
        let otherSessionDraftKey = SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: "ouroboros",
            sessionID: "session-2",
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1"
        )
        require(selectedDraftKey != otherSessionDraftKey, "draft key omitted parent session identity")
        require(
            SessionSteeringDraftKeyPolicy.exactKey(
                sourceID: "a:b",
                sessionID: "c",
                executionID: "d",
                scopeID: "e",
                attemptID: "f"
            ) != SessionSteeringDraftKeyPolicy.exactKey(
                sourceID: "a",
                sessionID: "b:c",
                executionID: "d",
                scopeID: "e",
                attemptID: "f"
            ),
            "draft key delimiter collision was accepted"
        )
        require(
            SessionComposerPresentationPolicy.passiveStatus(
                hasDraft: false,
                authorityExplanation: "Broker messaging unavailable",
                terminalStatus: "Terminal attachment expired"
            ) == "Terminal attachment expired · Steering unavailable",
            "terminal activation failure and steering availability were conflated"
        )
        require(
            SessionTerminalEntryPresentation.attachmentUnavailable(
                "The terminal is no longer open"
            ).summary == "The terminal is no longer open",
            "activation failure reason was not preserved for the visible terminal status"
        )
        require(
            !SessionTerminalActivationIntentPolicy.shouldArm(
                isGroup: true,
                status: "running",
                entry: .openSession(readOnly: false)
            ),
            "opening live activity armed a later automatic terminal takeover"
        )
        require(
            !SessionTerminalActivationIntentPolicy.shouldArm(
                isGroup: false,
                status: "running",
                entry: .openSession(readOnly: false)
            ),
            "a leaf armed group terminal discovery intent"
        )
        require(
            !SessionTerminalActivationIntentPolicy.shouldArm(
                isGroup: true,
                status: "completed",
                entry: .openSession(readOnly: true)
            ),
            "completed history armed terminal discovery intent"
        )
        require(
            SessionTerminalActivationIntentPolicy.resolve(
                hasPendingIntent: true,
                selectionMatchesIntent: true,
                entry: .none
            ) == .wait,
            "pending activation did not wait for the target overlay"
        )
        require(
            SessionTerminalActivationIntentPolicy.resolve(
                hasPendingIntent: true,
                selectionMatchesIntent: true,
                entry: .openSingle
            ) == .activate,
            "empty-to-one target discovery did not replay the original click"
        )
        require(
            SessionTerminalActivationIntentPolicy.resolve(
                hasPendingIntent: true,
                selectionMatchesIntent: true,
                entry: .revealRuns(3)
            ) == .revealRuns,
            "empty-to-many target discovery did not reveal agent runs"
        )
        require(
            SessionTerminalActivationIntentPolicy.resolve(
                hasPendingIntent: true,
                selectionMatchesIntent: false,
                entry: .openSingle
            ) == .none,
            "a stale click intent activated after the user changed selection"
        )
        let discovery = MCPSessionTargetDiscoveryResult(
            executionID: "exec-1",
            intentGeneration: 42,
            outcome: .empty
        )
        require(
            SessionTargetDiscoveryIntentPolicy.accepts(
                discovery,
                pendingExecutionID: "exec-1",
                pendingGeneration: 42,
                selectionStillMatches: true
            ),
            "an exact empty discovery result could not clear its pending Choose intent"
        )
        require(
            !SessionTargetDiscoveryIntentPolicy.accepts(
                discovery,
                pendingExecutionID: "exec-1",
                pendingGeneration: 43,
                selectionStillMatches: true
            ),
            "a stale discovery generation could clear a newer Choose intent"
        )
        require(
            !SessionTargetDiscoveryIntentPolicy.accepts(
                discovery,
                pendingExecutionID: "exec-2",
                pendingGeneration: 42,
                selectionStillMatches: true
            ),
            "a discovery result crossed execution identity"
        )
        require(
            !SessionTargetDiscoveryIntentPolicy.accepts(
                discovery,
                pendingExecutionID: "exec-1",
                pendingGeneration: 42,
                selectionStillMatches: false
            ),
            "a discovery result replayed after selection changed"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .openSession(readOnly: false),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true,
                steerableChildren: [false, true, false]
            ) == 1,
            "one exact steerable attempt was not promoted from its group"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .openSession(readOnly: false),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true,
                steerableChildren: [true, true]
            ) == nil,
            "an ambiguous group guessed a steering attempt"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .openSession(readOnly: false),
                isGroup: true,
                status: "completed",
                isProjectionTrusted: true,
                steerableChildren: [true]
            ) == nil,
            "completed history promoted stale steering authority"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .openSession(readOnly: false),
                isGroup: true,
                status: "active",
                isProjectionTrusted: false,
                steerableChildren: [true]
            ) == nil,
            "an untrusted projection promoted steering authority"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .openSingle,
                isGroup: true,
                status: "running",
                isProjectionTrusted: true,
                steerableChildren: [true, false]
            ) == nil,
            "a headless steering child overrode the visible Terminal action"
        )
        require(
            SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
                entry: .revealRuns(2),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true,
                steerableChildren: [true, false]
            ) == nil,
            "a headless steering child bypassed the visible Choose action"
        )
        let liveSessionAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .openSession(readOnly: false),
            isGroup: true,
            status: "running",
            isProjectionTrusted: true
        )
        require(liveSessionAffordance.stateLabel == "Open live session ›", "headless live session did not expose its streaming workspace")
        require(
            liveSessionAffordance.destination == .activity(readOnly: false),
            "headless live session was presented as a terminal destination"
        )
        require(liveSessionAffordance.isPrimaryAction, "headless live session primary click was inert")
        require(
            liveSessionAffordance.accessibilityHelp
                == "Click or press Return to enter this live streaming session. Messages and terminal entry remain scoped to exact agents inside it.",
            "headless session accessibility help did not describe the streaming workspace"
        )
        let singleAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .openSingle,
            isGroup: true,
            status: "running",
            isProjectionTrusted: true
        )
        require(singleAffordance.stateLabel == "Open live session ›", "single PTY group did not enter its live session")
        require(
            singleAffordance.destination == .activity(readOnly: false),
            "verified single PTY group bypassed the live session workspace"
        )
        let agentAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .revealAgents(4),
            isGroup: true,
            status: "running",
            isProjectionTrusted: true
        )
        require(agentAffordance.stateLabel == "Open live session ›", "headless fanout hid its live session workspace")
        require(
            agentAffordance.destination == .agentPicker(4),
            "headless fanout was presented as a terminal picker"
        )
        require(agentAffordance.isPrimaryAction, "headless fanout chooser was not a primary action")
        let unresolvedAgentAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .revealAgents(0),
            isGroup: true,
            status: "running",
            isProjectionTrusted: true
        )
        require(unresolvedAgentAffordance.stateLabel == "Open live session ›", "lazy fanout discovery had no session entry")
        let multiAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .revealRuns(3),
            isGroup: true,
            status: "running",
            isProjectionTrusted: true
        )
        require(multiAffordance.stateLabel == "Open live session ›", "fanout PTY group bypassed its session workspace")
        require(
            multiAffordance.destination == .activity(readOnly: false),
            "verified fanout PTYs bypassed the live session workspace"
        )
        let groupHistoryAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .openSession(readOnly: true),
            isGroup: true,
            status: "completed",
            isProjectionTrusted: true
        )
        require(groupHistoryAffordance.stateLabel == "View history ›", "completed group did not expose history")
        require(groupHistoryAffordance.isPrimaryAction, "completed history primary click was inert")
        let endedLeafAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .openSession(readOnly: true),
            isGroup: false,
            status: "completed",
            isProjectionTrusted: true
        )
        require(endedLeafAffordance.stateLabel == "View history ›", "completed attempt did not expose history")
        let unverifiedAffordance = SessionTerminalEntryAffordancePolicy.resolve(
            entry: .none,
            isGroup: true,
            status: "running",
            isProjectionTrusted: false
        )
        require(!unverifiedAffordance.isPrimaryAction, "unverified group exposed terminal discovery")
        require(
            unverifiedAffordance.destination == .none,
            "unverified MCP projection invented a primary destination"
        )
        require(
            SessionRailExpandablePolicy.resolve(
                hasChildren: false,
                isLazyCatalogCollection: false,
                isSessionGroup: true,
                isProjectionTrusted: true,
                isLive: true,
                hasExecutionIdentity: true,
                hasSessionAdapter: true
            ),
            "an empty live fanout could not expand to discover its exact agents"
        )
        require(
            !SessionRailExpandablePolicy.resolve(
                hasChildren: false,
                isLazyCatalogCollection: false,
                isSessionGroup: true,
                isProjectionTrusted: false,
                isLive: true,
                hasExecutionIdentity: true,
                hasSessionAdapter: true
            ),
            "an untrusted session exposed target discovery"
        )
        require(
            !SessionRailExpandablePolicy.resolve(
                hasChildren: false,
                isLazyCatalogCollection: false,
                isSessionGroup: true,
                isProjectionTrusted: true,
                isLive: false,
                hasExecutionIdentity: true,
                hasSessionAdapter: true
            ),
            "an ended empty session exposed live target discovery"
        )

        print("PASS: PTY rows open terminals while headless sessions open honest detail surfaces")
    }
}
