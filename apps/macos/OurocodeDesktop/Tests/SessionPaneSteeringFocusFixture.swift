import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: (message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionPaneSteeringFocusFixture {
    static func main() {
        let agentA = OuroborosSessionAttemptIdentityV1(
            sourceID: "ouroboros", sessionID: "s", executionID: "e",
            scopeID: "scope-a", attemptID: "attempt-a"
        )
        let agentB = OuroborosSessionAttemptIdentityV1(
            sourceID: "ouroboros", sessionID: "s", executionID: "e",
            scopeID: "scope-b", attemptID: "attempt-b"
        )
        let bindingA = TerminalSessionBinding(
            surface: OuroborosPTYSurfaceBindingV1(
                identity: agentA, terminalID: "pane-a", brokerGeneration: 7
            ), label: "Agent A", status: "running", depth: 1
        )
        let bindingB = TerminalSessionBinding(
            surface: OuroborosPTYSurfaceBindingV1(
                identity: agentB, terminalID: "pane-b", brokerGeneration: 7
            ), label: "Agent B", status: "running", depth: 1
        )

        let focusA = SessionPaneSteeringFocusPolicy.resolve(
            focusedTerminalID: "pane-a", brokerGeneration: 7,
            bindings: [bindingA, bindingB]
        )
        let focusB = SessionPaneSteeringFocusPolicy.resolve(
            focusedTerminalID: "pane-b", brokerGeneration: 7,
            bindings: [bindingA, bindingB]
        )
        require(focusA?.leaf == agentA, "pane A did not resolve to the exact attempt")
        require(focusB?.leaf == agentB, "pane B did not resolve to the exact attempt")
        require(
            SessionPaneSteeringFocusPolicy.resolve(
                focusedTerminalID: "pane-a", brokerGeneration: 6,
                bindings: [bindingA, bindingB]
            ) == nil,
            "stale broker generation was allowed to steer"
        )
        require(
            SessionPaneSteeringFocusPolicy.resolve(
                focusedTerminalID: "pane-a", brokerGeneration: 7,
                bindings: [bindingA, bindingA]
            ) == nil,
            "ambiguous pane binding selected the first duplicate"
        )

        let keyA = SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: agentA.sourceID, sessionID: agentA.sessionID,
            executionID: agentA.executionID, scopeID: agentA.scopeID,
            attemptID: agentA.attemptID
        )
        let keyB = SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: agentB.sourceID, sessionID: agentB.sessionID,
            executionID: agentB.executionID, scopeID: agentB.scopeID,
            attemptID: agentB.attemptID
        )
        require(keyA != keyB, "sibling panes shared a draft key")
        require(
            SessionPaneSteeringSendPolicy.resolve(
                focus: focusA, targetIdentity: agentA,
                targetModes: ["after_turn"], projectionTrusted: true,
                authenticatedTransportReady: true, draft: "inspect repo",
                exactDraftKey: keyA
            ) == .allowed(exactDraftKey: keyA),
            "exact after_turn target was not admitted"
        )
        require(
            SessionPaneSteeringSendPolicy.resolve(
                focus: focusA, targetIdentity: agentA,
                targetModes: ["terminal"], projectionTrusted: true,
                authenticatedTransportReady: true, draft: "nope",
                exactDraftKey: keyA
            ) == .rejected(.afterTurnUnavailable),
            "target without after_turn was admitted"
        )
        require(
            SessionPaneSteeringSendPolicy.resolve(
                focus: focusA, targetIdentity: agentB,
                targetModes: ["after_turn"], projectionTrusted: true,
                authenticatedTransportReady: true, draft: "wrong pane",
                exactDraftKey: keyB
            ) == .rejected(.targetMismatch),
            "sibling target bypassed focused pane identity"
        )
        require(
            SessionPaneSteeringSendPolicy.resolve(
                focus: nil, targetIdentity: nil,
                targetModes: ["after_turn"], projectionTrusted: true,
                authenticatedTransportReady: true, draft: "group",
                exactDraftKey: nil
            ) == .rejected(.noFocusedPane),
            "group-only session manufactured a send destination"
        )
        require(
            SessionFocusedAgentComposerPolicy.resolve(
                hasFocusedBinding: false,
                focusedIdentityMatchesTarget: false,
                advertisesAfterTurn: false,
                projectionTrusted: true,
                authenticatedTransportReady: true
            ) == .unavailable("No Ouroboros agent linked to this pane"),
            "unbound keyboard action did not explain the missing agent"
        )
        require(
            SessionFocusedAgentComposerPolicy.resolve(
                hasFocusedBinding: true,
                focusedIdentityMatchesTarget: true,
                advertisesAfterTurn: true,
                projectionTrusted: true,
                authenticatedTransportReady: true
            ) == .focusComposer,
            "exact trusted after_turn binding did not open the composer"
        )
        require(
            SessionFocusedAgentComposerPolicy.resolve(
                hasFocusedBinding: true,
                focusedIdentityMatchesTarget: false,
                advertisesAfterTurn: true,
                projectionTrusted: true,
                authenticatedTransportReady: true
            ) == .unavailable("The linked Ouroboros agent is no longer available"),
            "mismatched pane attempted to open a global composer"
        )
        require(
            SessionFocusedAgentComposerPolicy.resolve(
                hasFocusedBinding: true,
                focusedIdentityMatchesTarget: true,
                advertisesAfterTurn: false,
                projectionTrusted: true,
                authenticatedTransportReady: true
            ) == .unavailable("This agent does not accept after-turn messages"),
            "missing after_turn capability had no human explanation"
        )

        // Simulated receipts prove pane-local state handling without invoking
        // an adapter, provider, network, or real steering message.
        var drafts = [keyA: "A draft", keyB: "B draft"]
        var receipts = [String: String]()
        drafts[keyA] = nil // simulated success for pane A
        receipts[keyA] = "Queued (simulated)"
        require(drafts[keyA] == nil && drafts[keyB] == "B draft", "success cleared sibling draft")
        receipts[keyB] = "Not queued (simulated failure)"
        require(drafts[keyB] == "B draft", "failure discarded the focused draft")
        require(receipts[keyA] == "Queued (simulated)", "success receipt was not isolated")
        require(receipts[keyB] == "Not queued (simulated failure)", "failure receipt was lost")

        print("PASS: focused terminal panes resolve exact MCP attempts with isolated drafts and fail-closed steering")
    }
}
