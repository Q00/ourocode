import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionAgentMultiplexerFixture {
    static func candidate(
        _ index: Int,
        pty: Bool = false,
        enterable: Bool? = nil,
        steerable: Bool = true
    ) -> SessionAgentMultiplexerCandidate {
        SessionAgentMultiplexerCandidate(
            id: "node-\(index)",
            title: "Agent \(index)",
            status: "running",
            summary: "Working on acceptance criterion \(index)",
            executionID: "exec-\(index)",
            scopeID: "scope-\(index)",
            attemptID: "attempt-\(index)",
            hasPTY: pty,
            canEnterTerminal: enterable ?? pty,
            canSteer: steerable,
            draft: "draft-\(index)",
            receipt: "receipt-\(index)",
            unavailableReason: "View only"
        )
    }

    static func main() {
        let resolved = SessionAgentMultiplexerPolicy.resolve((1...6).map {
            candidate($0, pty: $0 == 2)
        })
        require(resolved.cards.count == 4, "multiplexer did not enforce the four-card memory/attention cap")
        require(resolved.overflowCount == 2, "overflow was not disclosed")
        require(resolved.cards[0].surfaceLabel == "Messages", "headless steering was presented as a terminal")
        require(resolved.cards[1].surfaceLabel == "Terminal ready", "verified PTY was not labelled independently")
        require(resolved.cards[0].primaryAction == .messageAgent, "headless steering did not expose Message Agent")
        require(resolved.cards[1].primaryAction == .enterTerminal, "PTY card did not expose Enter Terminal")
        require(resolved.cards[0].draft == "draft-1" && resolved.cards[1].draft == "draft-2", "independent drafts collapsed")
        require(resolved.cards[0].receipt == "receipt-1" && resolved.cards[1].receipt == "receipt-2", "independent receipts collapsed")
        require(resolved.cards[3].exactIdentity.contains("attempt attempt-4"), "exact delivery identity was lost")

        var malformed = candidate(7)
        malformed = SessionAgentMultiplexerCandidate(
            id: malformed.id,
            title: malformed.title,
            status: malformed.status,
            summary: malformed.summary,
            executionID: malformed.executionID,
            scopeID: malformed.scopeID,
            attemptID: "",
            hasPTY: malformed.hasPTY,
            canEnterTerminal: malformed.canEnterTerminal,
            canSteer: malformed.canSteer,
            draft: malformed.draft,
            receipt: malformed.receipt,
            unavailableReason: malformed.unavailableReason
        )
        let identityGuard = SessionAgentMultiplexerPolicy.resolve([
            candidate(1), candidate(1), malformed,
        ])
        require(identityGuard.cards.count == 1, "duplicate or incomplete exact identities reached the work plane")

        require(SessionAgentMultiplexerPolicy.columnCount(availableWidth: 760) == 2, "wide workspace did not use a 2-column grid")
        require(SessionAgentMultiplexerPolicy.columnCount(availableWidth: 619) == 1, "narrow workspace did not fall back to one column")

        let passive = SessionAgentMultiplexerPolicy.resolve([candidate(9, steerable: false)])
        require(!passive.cards[0].canSteer && passive.cards[0].primaryAction == .none, "read-only headless attempt gained an action")

        let terminalWithoutMessaging = SessionAgentMultiplexerPolicy.resolve([
            candidate(10, pty: true, steerable: false),
        ])
        require(
            terminalWithoutMessaging.cards[0].primaryAction == .enterTerminal
                && terminalWithoutMessaging.cards[0].canEnterTerminal
                && !terminalWithoutMessaging.cards[0].canSteer,
            "PTY entry was incorrectly coupled to MCP steering authority"
        )

        let currentActivation = SessionAgentMultiplexerPolicy.terminalActivationIsCurrent(
            expectedGeneration: 11,
            currentGeneration: 11,
            expectedGroupID: "group-a",
            selectedGroupID: "group-a",
            expectedChildID: "node-10",
            currentChildID: "node-10",
            detailWorkspaceVisible: true,
            exactIdentityStillMatches: true
        )
        require(currentActivation, "exact child activation was rejected inside its current group")
        require(
            !SessionAgentMultiplexerPolicy.terminalActivationIsCurrent(
                expectedGeneration: 11,
                currentGeneration: 12,
                expectedGroupID: "group-a",
                selectedGroupID: "group-a",
                expectedChildID: "node-10",
                currentChildID: "node-10",
                detailWorkspaceVisible: true,
                exactIdentityStillMatches: true
            ),
            "stale activation generation remained current"
        )
        require(
            !SessionAgentMultiplexerPolicy.terminalActivationIsCurrent(
                expectedGeneration: 11,
                currentGeneration: 11,
                expectedGroupID: "group-a",
                selectedGroupID: "group-b",
                expectedChildID: "node-10",
                currentChildID: "node-10",
                detailWorkspaceVisible: true,
                exactIdentityStillMatches: true
            ),
            "activation escaped its selected group context"
        )
        print("PASS: exact-agent multiplexer caps, isolates, labels, and adapts honestly")
    }
}
