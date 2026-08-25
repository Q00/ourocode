import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalSessionBindingFixture {
    static func main() {
        let first = TerminalSessionLeafIdentity(
            sourceID: "ouroboros",
            sessionID: "session-a",
            executionID: "execution-a",
            scopeID: "scope-a",
            attemptID: "attempt-a"
        )
        let second = TerminalSessionLeafIdentity(
            sourceID: "ouroboros",
            sessionID: "session-a",
            executionID: "execution-a",
            scopeID: "scope-b",
            attemptID: "attempt-b"
        )
        let bindings = [
            TerminalSessionBinding(
                surface: OuroborosPTYSurfaceBindingV1(
                    identity: first,
                    terminalID: "pty-1",
                    brokerGeneration: 7
                ),
                label: "Review renderer",
                status: "running",
                depth: 0
            ),
            TerminalSessionBinding(
                surface: OuroborosPTYSurfaceBindingV1(
                    identity: second,
                    terminalID: "pty-2",
                    brokerGeneration: 7
                ),
                label: "Review renderer",
                status: "running",
                depth: 0
            ),
        ]

        require(
            TerminalSessionBindingPolicy.terminalID(
                for: first,
                brokerGeneration: 7,
                bindings: bindings
            ) == "pty-1",
            "leaf did not resolve to its broker PTY"
        )
        require(
            TerminalSessionBindingPolicy.binding(
                for: first,
                brokerGeneration: 7,
                bindings: bindings
            ) == bindings[0],
            "exact activation lost the verified binding metadata"
        )
        require(
            TerminalSessionBindingPolicy.terminalID(
                for: second,
                brokerGeneration: 7,
                bindings: bindings
            ) == "pty-2",
            "duplicate labels collapsed into one PTY"
        )
        require(
            TerminalSessionBindingPolicy.leaf(
                for: "pty-2",
                brokerGeneration: 7,
                bindings: bindings
            ) == second,
            "PTY did not resolve back to its leaf"
        )
        require(
            TerminalSessionBindingPolicy.terminalID(
                for: first,
                brokerGeneration: 8,
                bindings: bindings
            ) == nil,
            "stale broker generation activated a reused terminal id"
        )
        let duplicateLeafBindings = bindings + [
            TerminalSessionBinding(
                surface: OuroborosPTYSurfaceBindingV1(
                    identity: first,
                    terminalID: "pty-conflict",
                    brokerGeneration: 7
                ),
                label: "Conflicting leaf",
                status: "running",
                depth: 1
            ),
        ]
        require(
            TerminalSessionBindingPolicy.binding(
                for: first,
                brokerGeneration: 7,
                bindings: duplicateLeafBindings
            ) == nil,
            "one leaf ambiguously selected the first of multiple terminals"
        )
        let duplicateTerminalBindings = bindings + [
            TerminalSessionBinding(
                surface: OuroborosPTYSurfaceBindingV1(
                    identity: first,
                    terminalID: "pty-2",
                    brokerGeneration: 7
                ),
                label: "Conflicting terminal",
                status: "running",
                depth: 1
            ),
        ]
        require(
            TerminalSessionBindingPolicy.leaf(
                for: "pty-2",
                brokerGeneration: 7,
                bindings: duplicateTerminalBindings
            ) == nil,
            "one terminal ambiguously selected the first of multiple leaves"
        )
        require(
            TerminalSessionBindingRevisionPolicy.accepts(
                expectedRevision: 3,
                currentRevision: 3,
                expectedBinding: bindings[0],
                leaf: first,
                brokerGeneration: 7,
                currentBindings: bindings
            ),
            "unchanged exact binding revision rejected broker list response"
        )
        require(
            !TerminalSessionBindingRevisionPolicy.accepts(
                expectedRevision: 3,
                currentRevision: 4,
                expectedBinding: bindings[0],
                leaf: first,
                brokerGeneration: 7,
                currentBindings: bindings
            ),
            "stale broker list response survived binding revision change"
        )
        require(
            !TerminalSessionBindingRevisionPolicy.accepts(
                expectedRevision: 3,
                currentRevision: 3,
                expectedBinding: bindings[0],
                leaf: first,
                brokerGeneration: 7,
                currentBindings: []
            ),
            "revoked MCP binding still authorized broker list response"
        )
        let rebound = TerminalSessionBinding(
            surface: OuroborosPTYSurfaceBindingV1(
                identity: first,
                terminalID: "pty-rebound",
                brokerGeneration: 7
            ),
            label: "Rebound leaf",
            status: "running",
            depth: 0
        )
        require(
            !TerminalSessionBindingRevisionPolicy.accepts(
                expectedRevision: 3,
                currentRevision: 3,
                expectedBinding: bindings[0],
                leaf: first,
                brokerGeneration: 7,
                currentBindings: [rebound]
            ),
            "changed terminal id reused an old binding revision"
        )
        require(bindings[0].tabTitle == "Review renderer", "tab title lost the leaf label")
        require(bindings[0].tabDetail == "Running", "tab detail lost the status")
        require(
            TerminalSessionBinding(
                surfaceResolution: .unbound(.missingTerminalID),
                label: "Review renderer",
                status: "running",
                depth: 0
            ) == nil,
            "unbound MCP leaf claimed a terminal tab"
        )
        require(
            TerminalSessionBindingPolicy.groupKey(first)
                == "execution:9:ouroboros:11:execution-a",
            "fanout leaves did not share an execution group"
        )
        require(
            TerminalSessionActivationResult.activated.isActivated,
            "activated result did not preserve success"
        )
        require(
            TerminalSessionActivationResult.unavailable(.noVerifiedBinding).isActivated == false,
            "unavailable activation was reported as success"
        )
        require(
            TerminalSessionActivationFailure.terminalNotOpen.summary == "The terminal is no longer open",
            "terminal activation failure lost its user-facing reason"
        )

        let splitWorkspace = [
            TerminalSessionOpenSurfaceTab(
                primaryTerminalID: "primary-a",
                workspaceTerminalIDs: ["primary-a", "agent-b"]
            )
        ]
        require(
            TerminalSessionOpenSurfacePolicy.resolve(
                terminalID: "agent-b", tabs: splitWorkspace
            ) == .splitPane(tabIndex: 0),
            "an existing split PTY was not resolved as an enterable pane"
        )
        require(
            TerminalSessionOpenSurfacePolicy.resolve(
                terminalID: "primary-a", tabs: splitWorkspace
            ) == .primary(tabIndex: 0),
            "a workspace primary was counted twice"
        )
        require(
            TerminalSessionOpenSurfacePolicy.resolve(
                terminalID: "agent-b",
                tabs: splitWorkspace + [
                    TerminalSessionOpenSurfaceTab(
                        primaryTerminalID: "agent-b",
                        workspaceTerminalIDs: ["agent-b"]
                    )
                ]
            ) == .ambiguous,
            "a PTY duplicated across a split and a tab did not fail closed"
        )
        require(
            TerminalSessionOpenSurfacePolicy.resolve(
                terminalID: "agent-c", tabs: splitWorkspace
            ) == .none,
            "an unopened PTY manufactured a local surface"
        )

        let adoption = { (
            expectedTerminalID: String,
            expectedGeneration: UInt64,
            currentGeneration: UInt64?,
            listedTerminalID: String,
            running: Bool,
            alreadyOpen: Bool,
            hasCapacity: Bool
        ) in
            TerminalSessionBrokerAdoptionPolicy.accepts(
                expectedTerminalID: expectedTerminalID,
                expectedBrokerGeneration: expectedGeneration,
                currentBrokerGeneration: currentGeneration,
                listedTerminalID: listedTerminalID,
                listedTerminalIsRunning: running,
                terminalAlreadyOpen: alreadyOpen,
                hasTabCapacity: hasCapacity
            )
        }
        require(
            adoption("pty-1", 7, 7, "pty-1", true, false, true),
            "an exact running broker PTY could not be adopted"
        )
        require(
            !adoption("pty-1", 7, 8, "pty-1", true, false, true),
            "a stale broker generation adopted a PTY"
        )
        require(
            !adoption("pty-1", 7, 7, "pty-2", true, false, true),
            "a different listed terminal adopted a PTY"
        )
        require(
            !adoption("pty-1", 7, 7, "pty-1", false, false, true),
            "an exited broker PTY was adopted"
        )
        require(
            !adoption("pty-1", 7, 7, "pty-1", true, true, true),
            "an already-open PTY was duplicated"
        )
        require(
            !adoption("pty-1", 7, 7, "pty-1", true, false, false),
            "a PTY bypassed the tab capacity limit"
        )

        print(
            "PASS: session leaves bind uniquely and adopt only exact current-generation broker terminals"
        )
    }
}
