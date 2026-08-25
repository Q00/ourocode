import AppKit
import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private struct ExpansionFixtureNode {
    let id: String
    let liveBucket: Bool
    let children: [ExpansionFixtureNode]

    init(_ id: String, liveBucket: Bool = false, children: [ExpansionFixtureNode] = []) {
        self.id = id
        self.liveBucket = liveBucket
        self.children = children
    }
}

@main
private enum SessionRailPresentationFixture {
    static func main() {
        _ = NSApplication.shared

        let leaf = SessionRailPresentationPolicy.row(.sessionLeaf)
        require(leaf.height == 50, "session leaf did not receive two-line height")
        require(leaf.usesTwoLines, "session leaf detail remained hidden")
        require(leaf.titleTruncation == .byTruncatingMiddle, "session identifier did not middle-truncate")

        let item = SessionRailPresentationPolicy.row(.item)
        require(item.titleTruncation == .byTruncatingMiddle, "MCP identifier did not middle-truncate")
        let emptySessions = SessionRailPresentationPolicy.row(.collection, emptySessionsCollection: true)
        require(emptySessions.height == 50 && emptySessions.usesTwoLines, "empty Sessions status lost its detail line")
        require(
            SessionCollectionEmptyPresentationPolicy.resolve(sourceStatus: "starting")
                == SessionCollectionEmptyPresentation(
                    title: "Finding sessions…",
                    detail: "Checking Ouroboros for active and recent runs."
                ),
            "session discovery did not expose its in-progress state"
        )
        require(
            SessionCollectionEmptyPresentationPolicy.resolve(sourceStatus: "connected")
                == SessionCollectionEmptyPresentation(
                    title: "No sessions yet",
                    detail: "Agent runs appear here automatically when Ouroboros starts them."
                ),
            "successful empty discovery looked like a broken rail"
        )
        require(
            SessionCollectionEmptyPresentationPolicy.resolve(sourceStatus: "offline")
                == SessionCollectionEmptyPresentation(
                    title: "Sessions unavailable",
                    detail: "Ourocode will retry while Sessions is open."
                ),
            "an unavailable source looked like successful empty discovery"
        )

        let title = NSTextField(labelWithString: "short")
        let detail = NSTextField(labelWithString: "detail")
        let state = NSTextField(labelWithString: "Completed")
        SessionRailPresentationPolicy.configureTextPriority(title: title, state: state)
        SessionRailPresentationPolicy.configureTooltips(
            title: title,
            detail: detail,
            fullTitle: "attempt-1234567890",
            fullDetail: "Full session detail"
        )
        require(
            state.contentCompressionResistancePriority(for: .horizontal) == .required,
            "state label can be compressed before the identifier"
        )
        require(
            title.contentCompressionResistancePriority(for: .horizontal) == .defaultLow,
            "identifier did not yield space to state"
        )
        require(title.toolTip == "attempt-1234567890", "full title tooltip missing")
        require(detail.toolTip == "Full session detail", "full detail tooltip missing")

        require(
            SessionComposerPresentationPolicy.resolve(
                hasSessionSelection: true,
                hasVerifiedAuthority: false
            ) == .passiveReadOnly,
            "unverified authority exposed the composer"
        )
        require(SessionComposerPresentation.passiveReadOnly.height == 32, "read-only status is not compact")
        require(SessionComposerPresentation.verifiedComposer.height == 124, "verified composer height changed")
        require(
            SessionComposerPresentationPolicy.resolve(
                hasSessionSelection: true,
                hasVerifiedAuthority: true,
                hasExactTarget: false
            ) == .passiveReadOnly,
            "authenticated transport exposed a composer for completed history without an exact target"
        )
        require(
            SessionComposerPresentationPolicy.resolve(
                hasSessionSelection: false,
                hasVerifiedAuthority: true
            ) == .hidden,
            "composer remained visible without a session selection"
        )
        require(
            SessionComposerPresentationPolicy.passiveStatusHelp(
                hasDraft: true,
                authorityExplanation: "Unavailable"
            ).contains("Draft saved"),
            "passive mode did not preserve draft state in its status"
        )
        require(
            SessionComposerPresentationPolicy.passiveStatusHelp(
                hasDraft: false,
                authorityExplanation: "Read-only · Authenticated broker messaging is not connected"
            ) == "Read-only · Authenticated broker messaging is not connected",
            "passive mode duplicated its read-only prefix"
        )

        require(
            SessionRailModePresentationPolicy.headerTitle(for: .sessions) == "Sessions"
                && SessionRailModePresentationPolicy.headerTitle(for: .mcp) == "MCP",
            "rail modes stopped separating sessions from the MCP registry"
        )
        require(SessionRailMode.initial == .mcp, "the general MCP registry is not the initial view")

        require(
            MCPSessionsLinkPresentationPolicy.resolve(
                hasSessionsExtension: false,
                liveCount: 2,
                totalCount: 3
            ) == nil,
            "a generic MCP source invented an Ouroboros Sessions link"
        )
        let sessionsLink = MCPSessionsLinkPresentationPolicy.resolve(
            hasSessionsExtension: true,
            liveCount: 2,
            totalCount: 5
        )
        require(sessionsLink?.title == "Sessions", "MCP Sessions link lost its familiar label")
        require(sessionsLink?.detail == "2 active · choose a session", "live session count was hidden")
        require(sessionsLink?.stateLabel == "Browse sessions ›", "multiple live sessions did not expose a chooser")
        require(
            MCPSessionsLinkPresentationPolicy.resolve(
                hasSessionsExtension: true,
                liveCount: 1,
                totalCount: 5
            )?.stateLabel == "Open live session ›",
            "single live MCP session did not expose direct entry"
        )
        require(
            MCPSessionsLinkPresentationPolicy.resolve(
                hasSessionsExtension: true,
                liveCount: 2,
                totalCount: 4
            )?.stateLabel == "Browse sessions ›",
            "multi-session MCP link did not preserve an explicit chooser"
        )
        require(
            MCPSessionsLinkPresentationPolicy.resolve(
                hasSessionsExtension: true,
                liveCount: 0,
                totalCount: 4
            )?.stateLabel == "Browse history ›",
            "completed MCP sessions did not expose history"
        )
        require(sessionsLink?.accessibilityHelp.contains("browse the active sessions") == true,
                "MCP Sessions link lost its navigation explanation")
        let sessionsLinkID = MCPSessionsLinkPresentationPolicy.id(sourceID: "ouroboros")
        require(
            MCPSessionsLinkPresentationPolicy.matches(
                nodeID: sessionsLinkID,
                sourceID: "ouroboros"
            ),
            "MCP Sessions link could not route to the session navigator"
        )
        require(
            MCPSessionsLinkPresentationPolicy.matches(
                nodeID: MCPSessionsLinkPresentationPolicy.sessionIndexResourceID(
                    sourceID: "ouroboros"
                ),
                sourceID: "ouroboros"
            ),
            "the standard Ouroboros session-index resource remained an inert descriptor"
        )
        require(
            !MCPSessionsLinkPresentationPolicy.matches(
                nodeID: sessionsLinkID,
                sourceID: "another-source"
            ),
            "MCP Sessions link crossed source identity"
        )
        require(
            !MCPSessionsLinkPresentationPolicy.matches(
                nodeID: MCPSessionsLinkPresentationPolicy.sessionIndexResourceID(
                    sourceID: "ouroboros"
                ),
                sourceID: "another-source"
            ),
            "session-index navigation crossed its MCP source identity"
        )

        let collapsedMultiSourceLanding = SessionCrossLinkLandingPolicy.resolve(
            preferredSourceID: "provider-b",
            candidates: [
                SessionCrossLinkCandidate(
                    id: "session-a",
                    sourceID: "provider-a",
                    status: "running",
                    kind: .sessionGroup,
                    ancestorIDs: ["source-a", "live-a"]
                ),
                SessionCrossLinkCandidate(
                    id: "session-b",
                    sourceID: "provider-b",
                    status: "running",
                    kind: .sessionGroup,
                    ancestorIDs: ["source-b", "live-b"]
                ),
            ]
        )
        require(
            collapsedMultiSourceLanding == SessionCrossLinkLanding(
                destinationID: "session-b",
                ancestorIDsToExpand: ["source-b", "live-b"]
            ),
            "cross-link ignored its provider or retained collapsed ancestors"
        )

        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 1,
                isCompleted: false
            ) == .openSingle,
            "a group with one verified PTY did not become a direct terminal entry"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 3,
                isCompleted: false
            ) == .revealRuns(3),
            "fanout terminals did not ask the rail to reveal their agent runs"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: true,
                isProjectionTrusted: true,
                advertisedTerminalCount: 0,
                isCompleted: true
            ) == .openSession(readOnly: true),
            "ended session did not expose its read-only detail surface"
        )
        require(
            SessionTerminalEntryPolicy.resolve(
                isGroup: false,
                isProjectionTrusted: false,
                advertisedTerminalCount: 1,
                isCompleted: false
            ) == .none,
            "unverified MCP metadata exposed terminal entry"
        )
        require(
            SessionTerminalEntryAffordancePolicy.resolve(
                entry: .openSession(readOnly: false),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true
            ).stateLabel == "Open live session ›",
            "headless session action did not name its steering destination"
        )
        require(
            SessionTerminalEntryAffordancePolicy.resolve(
                entry: .revealAgents(3),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true
            ).stateLabel == "Open live session ›",
            "headless fanout did not expose direct multi-agent steering"
        )
        require(
            SessionTerminalEntryAffordancePolicy.resolve(
                entry: .openSingle,
                isGroup: false,
                status: "running",
                isProjectionTrusted: true
            ).stateLabel == "Open terminal ›",
            "PTY session action did not name its terminal destination"
        )
        require(
            SessionTerminalEntryAffordancePolicy.resolve(
                entry: .revealRuns(3),
                isGroup: true,
                status: "running",
                isProjectionTrusted: true
            ).stateLabel == "Open live session ›",
            "fanout session action did not name its terminal chooser"
        )
        require(
            SessionTerminalEntryAffordancePolicy.resolve(
                entry: .openSession(readOnly: true),
                isGroup: true,
                status: "completed",
                isProjectionTrusted: true
            ).stateLabel == "View history ›",
            "completed session action did not name its history destination"
        )
        require(
            SessionComposerPresentationPolicy.passiveStatus(
                hasDraft: false,
                authorityExplanation: "Unavailable",
                terminalStatus: "Run ended · No live terminal"
            ) == "Run ended · No live terminal · Steering unavailable",
            "terminal and steering availability were not separated"
        )

        let expansionRoots = [
            ExpansionFixtureNode("source-a", children: [
                ExpansionFixtureNode("live-a", liveBucket: true, children: [
                    ExpansionFixtureNode("execution-a", children: [
                        ExpansionFixtureNode("attempt-a"),
                    ]),
                ]),
                ExpansionFixtureNode("recent-a", children: [
                    ExpansionFixtureNode("history-a"),
                ]),
            ]),
            ExpansionFixtureNode("source-b", children: [
                ExpansionFixtureNode("live-b", liveBucket: true),
            ]),
        ]
        let requiredExpansion = SessionRailExpansionPolicy.requiredExpansionIDs(
            roots: expansionRoots,
            selectedNodeID: "attempt-a",
            id: \.id,
            children: \.children,
            isLiveBucket: \.liveBucket
        )
        require(
            requiredExpansion == Set(["source-a", "live-a", "execution-a", "live-b"]),
            "polling did not retain every live bucket and the selected steering path"
        )
        require(
            !requiredExpansion.contains("recent-a"),
            "ordinary history disclosure stopped respecting user control"
        )
        let discoveredAttemptExpansion = SessionRailExpansionPolicy.requiredExpansionIDs(
            roots: expansionRoots,
            selectedNodeID: "execution-a",
            id: \.id,
            children: \.children,
            isLiveBucket: \.liveBucket
        )
        require(
            discoveredAttemptExpansion.contains("execution-a"),
            "an opened session collapsed when its exact steering attempt arrived"
        )

        print("PASS: session rows expose honest terminal entry independently from steering authority")
    }
}
