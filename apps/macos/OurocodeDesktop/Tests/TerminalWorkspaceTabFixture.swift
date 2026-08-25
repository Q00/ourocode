import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TerminalWorkspaceTabError.layoutIdentityMismatch
    }
}

@main
@MainActor
private enum TerminalWorkspaceTabFixture {
    static func main() {
        do {
            try validatesOneLeafCreationAndSnapshot()
            try validatesExactDuplicateGuard()
            try validatesCloseAndTerminatePolicy()
            try validatesGenerationTokensAndAdmissionMetadata()
            try validatesAtomicSplitFocusAndCloseMutation()
            try validatesRecursiveFourPaneCommands()
            try validatesPrimaryClosePromotionSuccessor()
            print(
                "PASS: workspace creation, exact-ID guard, close/terminate policy, "
                    + "recursive 1→2→3→4 split/focus/close/equalize/maximize, "
                    + "pane admission, and generation tokens"
            )
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func validatesOneLeafCreationAndSnapshot() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "terminal-one",
            displaySequence: 7,
            title: "zsh"
        )
        let snapshot = try workspace.snapshot()
        try require(snapshot.tabID == workspace.id, "snapshot lost workspace identity")
        try require(snapshot.projectionGeneration == 1, "one-leaf projection generation must start at one")
        try require(snapshot.layoutRevision == 0, "one-leaf layout revision must start at zero")
        try require(snapshot.focusedTerminalID == "terminal-one", "one-leaf focus must be exact")
        try require(snapshot.leaves.count == 1, "one-leaf workspace created more than one leaf")
        try require(snapshot.leaves[0].terminalID == "terminal-one", "leaf terminal identity changed")
        try require(workspace.paneCount == 1, "one-leaf workspace pane count is not one")
        let admission = try workspace.pane(for: "terminal-one").admission
        try require(
            admission == TerminalPaneAdmissionMetadata(tier: .normal, paneGeneration: 1),
            "one-leaf pane did not retain normal admission metadata"
        )
    }

    private static func validatesExactDuplicateGuard() throws {
        do {
            _ = try TerminalWorkspaceTab(
                terminalID: "terminal-occupied",
                displaySequence: 1,
                title: "duplicate",
                occupiedTerminalIDs: ["terminal-occupied"]
            )
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalWorkspaceTabError.duplicateTerminalID("terminal-occupied") {
            // Expected: duplicate matching is exact and case-sensitive.
        }

        let caseDistinct = try TerminalWorkspaceTab(
            terminalID: "Terminal-occupied",
            displaySequence: 2,
            title: "case-distinct",
            occupiedTerminalIDs: ["terminal-occupied"]
        )
        try require(caseDistinct.paneCount == 1, "an exact-ID guard rejected a distinct ID")
    }

    private static func validatesCloseAndTerminatePolicy() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "terminal-policy",
            displaySequence: 3,
            title: "policy"
        )
        let closeDecision = try workspace.removalDecision(
            for: "terminal-policy",
            disposition: .closeView
        )
        try require(
            closeDecision == .releaseView(terminalID: "terminal-policy"),
            "close view was not a non-destructive release decision"
        )
        let terminateDecision = try workspace.removalDecision(
            for: "terminal-policy",
            disposition: .terminateSession
        )
        try require(
            terminateDecision == .terminateBrokerSession(terminalID: "terminal-policy"),
            "terminate view was not an explicit broker termination decision"
        )
        do {
            _ = try workspace.removalDecision(for: "wrong-terminal", disposition: .closeView)
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalWorkspaceTabError.missingPane("wrong-terminal") {
            // Exact terminal ID lookup must fail closed.
        }
        try require(workspace.paneCount == 1, "removal policy mutated the one-leaf model")
    }

    private static func validatesGenerationTokensAndAdmissionMetadata() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "terminal-generation",
            displaySequence: 4,
            title: "generation"
        )
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let surfaceInstanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let attachment = BrokerAttachment.paneProjectionFixtureAttachment(
            terminalID: "terminal-generation",
            brokerGeneration: 2,
            connectionID: connectionID,
            inputEpoch: 3,
            leaseID: "lease-generation",
            layoutEpoch: 1
        )
        let token = try workspace.projectionToken(
            for: "terminal-generation",
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: 1
        )
        try require(
            PaneProjectionTokenGuard.accepts(token, current: token),
            "the current tab/pane generation token was rejected"
        )

        workspace.advanceProjectionGeneration()
        let tabStale = try workspace.projectionToken(
            for: "terminal-generation",
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: 1
        )
        try require(
            !PaneProjectionTokenGuard.accepts(token, current: tabStale),
            "a stale tab generation token was accepted"
        )

        let pane = try workspace.pane(for: "terminal-generation")
        pane.advanceGeneration()
        let paneStale = try workspace.projectionToken(
            for: "terminal-generation",
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: 1
        )
        try require(
            !PaneProjectionTokenGuard.accepts(tabStale, current: paneStale),
            "a stale pane generation token was accepted"
        )
        try require(
            pane.admission.paneGeneration == 2,
            "pane admission metadata did not follow pane generation"
        )
    }

    private static func validatesAtomicSplitFocusAndCloseMutation() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "terminal-left",
            displaySequence: 5,
            title: "split"
        )
        let originalGeneration = workspace.projectionGeneration
        let initialRevision = try workspace.snapshot().layoutRevision
        let divider = try workspace.splitFocused(
            axis: .leftRight,
            newTerminalID: "terminal-right",
            expectedRevision: initialRevision,
            authoritativeTerminalIDs: ["terminal-left", "terminal-right"]
        )
        try require(divider != 0, "split did not return a stable divider")
        try require(workspace.paneCount == 2, "split did not admit exactly one pane")
        try require(workspace.focusedTerminalID == "terminal-right", "new split did not receive focus")
        try require(
            workspace.projectionGeneration > originalGeneration,
            "split did not invalidate the tab projection generation"
        )
        let splitSnapshot = try workspace.snapshot()
        try require(
            splitSnapshot.leaves.map(\.terminalID) == ["terminal-left", "terminal-right"],
            "split layout and pane map diverged"
        )

        do {
            _ = try workspace.splitFocused(
                axis: .topBottom,
                newTerminalID: "terminal-right",
                expectedRevision: splitSnapshot.layoutRevision,
                authoritativeTerminalIDs: ["terminal-left", "terminal-right"]
            )
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalWorkspaceTabError.duplicateTerminalID("terminal-right") {
            // Duplicate rejection must not mutate either owner.
        }
        try require(workspace.paneCount == 2, "duplicate split mutated the pane map")
        let duplicateRejectedSnapshot = try workspace.snapshot()
        try require(duplicateRejectedSnapshot == splitSnapshot, "duplicate split mutated the layout")

        let revisionBeforeUnauthorized = try workspace.snapshot().layoutRevision
        do {
            _ = try workspace.splitFocused(
                axis: .topBottom,
                newTerminalID: "phantom-terminal",
                expectedRevision: revisionBeforeUnauthorized,
                authoritativeTerminalIDs: ["terminal-left", "terminal-right"]
            )
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalWorkspaceTabError.unauthorizedTerminalID("phantom-terminal") {
            // The layout accepts only a broker-authoritative terminal set.
        }
        try require(workspace.paneCount == 2, "unauthorized split admitted a phantom pane")

        let generationBeforeMove = workspace.projectionGeneration
        let revisionBeforeMove = try workspace.snapshot().layoutRevision
        let moved = try workspace.moveFocus(.left, expectedRevision: revisionBeforeMove)
        try require(moved.moved, "directional focus did not move")
        try require(workspace.focusedTerminalID == "terminal-left", "directional focus chose the wrong pane")
        try require(
            workspace.projectionGeneration > generationBeforeMove,
            "focus move did not invalidate projection tokens"
        )
        let generationBeforeBlockedMove = workspace.projectionGeneration
        let blockedRevision = try workspace.snapshot().layoutRevision
        let blocked = try workspace.moveFocus(.left, expectedRevision: blockedRevision)
        try require(!blocked.moved, "outward focus unexpectedly moved")
        try require(
            workspace.projectionGeneration == generationBeforeBlockedMove,
            "blocked focus invalidated a stable projection"
        )

        do {
            _ = try workspace.moveFocus(.right, expectedRevision: initialRevision)
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalWorkspaceTabError.staleLayoutRevision(
            expected: initialRevision,
            actual: revisionBeforeMove
        ) {
            // A delayed callback cannot mutate a newer layout.
        }
        try require(
            workspace.focusedTerminalID == "terminal-left",
            "stale focus callback changed the selected pane"
        )

        let revisionBeforeClose = try workspace.snapshot().layoutRevision
        let remainingFocus = try workspace.closePane(
            terminalID: "terminal-left",
            expectedRevision: revisionBeforeClose
        )
        try require(remainingFocus == "terminal-right", "close did not repair focus")
        try require(workspace.paneCount == 1, "close did not remove exactly one pane")
        try require(!workspace.canCloseFocusedPane, "last pane remained closable")
        let collapsed = try workspace.snapshot()
        try require(
            collapsed.leaves.count == 1
                && collapsed.leaves[0].terminalID == "terminal-right"
                && collapsed.leaves[0].width == 1_000_000,
            "close did not collapse the surviving pane to full size"
        )
    }

    private static func validatesRecursiveFourPaneCommands() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "pane-1",
            displaySequence: 6,
            title: "recursive"
        )
        let authoritative: Set<String> = ["pane-1", "pane-2", "pane-3", "pane-4", "pane-5"]
        for (terminalID, axis) in [
            ("pane-2", TerminalSplitAxis.leftRight),
            ("pane-3", TerminalSplitAxis.topBottom),
            ("pane-4", TerminalSplitAxis.leftRight),
        ] {
            let revision = try workspace.snapshot().layoutRevision
            _ = try workspace.splitFocused(
                axis: axis,
                newTerminalID: terminalID,
                expectedRevision: revision,
                authoritativeTerminalIDs: authoritative
            )
        }
        var snapshot = try workspace.snapshot()
        try require(snapshot.leaves.count == 4, "recursive split did not reach four panes")
        try require(Set(snapshot.leaves.map(\.terminalID)) == Set(authoritative.subtracting(["pane-5"])), "four-pane identities diverged")
        let canSplitFifth = try workspace.canSplitFocused()
        try require(!canSplitFifth, "four-pane production cap did not close split admission")
        do {
            _ = try workspace.splitFocused(
                axis: .topBottom,
                newTerminalID: "pane-5",
                expectedRevision: snapshot.layoutRevision,
                authoritativeTerminalIDs: authoritative
            )
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        } catch TerminalSplitLayoutBridgeError.ffi(_, .limitExceeded) {
            // Eight-pane or unbounded fanout is intentionally unavailable.
        }

        try workspace.maximizeFocused(expectedRevision: snapshot.layoutRevision)
        snapshot = try workspace.snapshot()
        try require(snapshot.maximizedTerminalID == "pane-4", "focused pane did not maximize")
        try require(snapshot.leaves.count == 4, "maximize discarded recursive identity leaves")
        try require(snapshot.presentationLeaves.count == 1, "maximize left background panes visible")
        try require(snapshot.presentationLeaves[0].width == 1_000_000, "maximized pane did not fill width")

        try workspace.restoreMaximized(expectedRevision: snapshot.layoutRevision)
        snapshot = try workspace.snapshot()
        try require(snapshot.maximizedTerminalID == nil, "restore left maximize state behind")
        try require(snapshot.presentationLeaves == snapshot.leaves, "restore did not recover tree geometry")

        _ = try workspace.equalize(expectedRevision: snapshot.layoutRevision)
        snapshot = try workspace.snapshot()
        try require(snapshot.leaves.count == 4, "equalize changed pane cardinality")

        let moved = try workspace.moveFocus(.left, expectedRevision: snapshot.layoutRevision)
        try require(moved.moved, "four-pane directional focus did not move")
        snapshot = try workspace.snapshot()
        let closedID = snapshot.focusedTerminalID
        _ = try workspace.closePane(
            terminalID: closedID,
            expectedRevision: snapshot.layoutRevision
        )
        snapshot = try workspace.snapshot()
        try require(snapshot.leaves.count == 3, "focused close did not collapse four to three")
        try require(!snapshot.leaves.contains(where: { $0.terminalID == closedID }), "focused close retained removed identity")
    }

    private static func validatesPrimaryClosePromotionSuccessor() throws {
        let workspace = try TerminalWorkspaceTab(
            terminalID: "primary",
            displaySequence: 8,
            title: "promotion"
        )
        let authoritative: Set<String> = ["primary", "survivor-1", "survivor-2"]
        var revision = try workspace.snapshot().layoutRevision
        _ = try workspace.splitFocused(
            axis: .leftRight,
            newTerminalID: "survivor-1",
            expectedRevision: revision,
            authoritativeTerminalIDs: authoritative
        )
        revision = try workspace.snapshot().layoutRevision
        _ = try workspace.splitFocused(
            axis: .topBottom,
            newTerminalID: "survivor-2",
            expectedRevision: revision,
            authoritativeTerminalIDs: authoritative
        )
        revision = try workspace.snapshot().layoutRevision
        try workspace.focus(terminalID: "primary", expectedRevision: revision)
        let beforePromotion = try workspace.snapshot()
        let successor = try workspace.closePane(
            terminalID: "primary",
            expectedRevision: beforePromotion.layoutRevision
        )
        try require(successor == "survivor-1", "primary close chose a non-deterministic promotion successor")
        let promoted = try workspace.snapshot()
        try require(promoted.focusedTerminalID == successor, "promotion successor did not own focus")
        try require(promoted.layoutRevision == beforePromotion.layoutRevision + 1, "primary close was not one layout CAS")
        try require(promoted.leaves.count == 2, "primary close removed more than one identity")
        try require(!promoted.leaves.contains(where: { $0.terminalID == "primary" }), "closed primary remained projected")
    }
}
