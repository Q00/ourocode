import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TerminalSplitLayoutBridgeError.invalidABIOutput("Fixture assertion failed: \(message)")
    }
}

private func requireFFIError(
    _ expected: TerminalSplitLayoutFFIResult,
    _ operation: () throws -> Void,
    _ message: String
) throws {
    do {
        try operation()
        throw TerminalSplitLayoutBridgeError.invalidABIOutput(
            "Fixture assertion failed: \(message) did not throw"
        )
    } catch let TerminalSplitLayoutBridgeError.ffi(_, result) {
        try require(result == expected, "\(message) returned \(result), expected \(expected)")
    }
}

@main
@MainActor
private enum TerminalSplitLayoutBridgeFixture {
    static func main() {
        do {
            try validateConfigurationAndTerminalIDs()
            try validateOneLeafOwner()
            try validateTwoLeafOwnerAndDividerIntents()
            try validateFourLeafRecursiveOwner()
            try validateRAIIReleasePath()
            print(
                "PASS: production Swift split owner recursive one-to-four snapshot, focus, split, "
                    + "close, equalize, divider preview/commit/cancel/keyboard, cap, and RAII"
            )
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func validateConfigurationAndTerminalIDs() throws {
        try require(
            TerminalSplitLayoutConfiguration.normal.maxLeaves == 4,
            "normal production layout must be capped at four leaves"
        )
        do {
            _ = try TerminalSplitLayoutConfiguration(maxLeaves: 5, maxDepth: 8)
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Fixture assertion failed: five-leaf production configuration was accepted"
            )
        } catch TerminalSplitLayoutBridgeError.invalidConfiguration {
            // Expected.
        }
        do {
            _ = try TerminalSplitLayoutConfiguration(maxLeaves: 2, maxDepth: 9)
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Fixture assertion failed: over-depth configuration was accepted"
            )
        } catch TerminalSplitLayoutBridgeError.invalidConfiguration {
            // Expected.
        }
        do {
            _ = try TerminalSplitLayoutBridge(initialTerminalID: "bad\nterminal")
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Fixture assertion failed: control-bearing terminal ID was accepted"
            )
        } catch TerminalSplitLayoutBridgeError.invalidTerminalID {
            // Expected.
        }
        do {
            _ = try TerminalSplitLayoutBridge(initialTerminalID: String(repeating: "é", count: 129))
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Fixture assertion failed: oversized UTF-8 terminal ID was accepted"
            )
        } catch TerminalSplitLayoutBridgeError.invalidTerminalID {
            // Expected.
        }
    }

    private static func validateOneLeafOwner() throws {
        let bridge = try TerminalSplitLayoutBridge(initialTerminalID: "terminal-one")
        let snapshot = try bridge.snapshot()
        try require(snapshot.revision == 0, "new one-leaf revision must be zero")
        try require(snapshot.focusedTerminalID == "terminal-one", "initial focus was lost")
        try require(snapshot.leaves.count == 1, "one-leaf snapshot has wrong cardinality")
        try require(
            snapshot.leaves[0]
                == TerminalSplitLeafGeometry(
                    nodeID: 1,
                    terminalID: "terminal-one",
                    x: 0,
                    y: 0,
                    width: 1_000_000,
                    height: 1_000_000
                ),
            "one leaf must occupy the full normalized layout"
        )
        let canSplit = try bridge.canSplitFocused()
        try require(canSplit, "normal one-leaf layout should be splittable")
        let blocked = try bridge.moveFocus(.left)
        try require(!blocked.moved, "one-leaf directional focus unexpectedly moved")
        try require(blocked.focusedTerminalID == "terminal-one", "blocked focus changed identity")
        try requireFFIError(.cannotCloseLastLeaf, {
            try bridge.close(terminalID: "terminal-one")
        }, "last-leaf close")
    }

    private static func validateTwoLeafOwnerAndDividerIntents() throws {
        let configuration = try TerminalSplitLayoutConfiguration(maxLeaves: 2, maxDepth: 8)
        let bridge = try TerminalSplitLayoutBridge(
            initialTerminalID: "terminal-a",
            configuration: configuration
        )
        let divider = try bridge.splitFocused(
            axis: .leftRight,
            newTerminalID: "terminal-b",
            placement: .after
        )
        try require(divider != 0, "split must return a stable nonzero divider")
        var snapshot = try bridge.snapshot()
        try require(snapshot.revision == 1, "split must advance the layout revision once")
        try require(snapshot.focusedTerminalID == "terminal-b", "new split leaf must receive focus")
        try require(snapshot.leaves.map(\.terminalID) == ["terminal-a", "terminal-b"], "split order changed")
        try require(snapshot.leaves[0].width == 500_000, "first half geometry is not 50 percent")
        try require(snapshot.leaves[1].x == 500_000, "second half geometry has the wrong origin")
        let canSplit = try bridge.canSplitFocused()
        try require(!canSplit, "two-leaf configured limit was not enforced")
        try requireFFIError(.limitExceeded, {
            _ = try bridge.splitFocused(axis: .topBottom, newTerminalID: "terminal-c")
        }, "configured leaf limit")

        let movedLeft = try bridge.moveFocus(.left)
        try require(movedLeft.moved, "left focus did not move between horizontal panes")
        try require(movedLeft.focusedTerminalID == "terminal-a", "left focus chose the wrong pane")
        try bridge.focus(terminalID: "terminal-b")
        let explicitlyFocused = try bridge.snapshot()
        try require(explicitlyFocused.focusedTerminalID == "terminal-b", "explicit focus did not stick")

        let began = try bridge.beginDividerDrag(dividerNodeID: divider)
        try require(began.ratioBasisPoints == 5_000, "drag did not begin at committed ratio")
        let preview = try bridge.updateDividerDrag(positionFromStart: 700, availableSpan: 1_000)
        try require(preview.ratioBasisPoints == 7_000, "pointer preview ratio is incorrect")
        let cancelled = try bridge.cancelDividerDrag()
        try require(cancelled.ratioBasisPoints == 5_000, "cancel did not restore committed ratio")
        let cancelledSnapshot = try bridge.snapshot()
        try require(cancelledSnapshot.revision == 1, "cancel changed the committed revision")

        _ = try bridge.beginDividerDrag(dividerNodeID: divider)
        let unchangedCommit = try bridge.commitDividerDrag()
        try require(unchangedCommit == nil, "unchanged divider commit emitted a resize intent")

        _ = try bridge.beginDividerDrag(dividerNodeID: divider)
        _ = try bridge.updateDividerDrag(positionFromStart: 600, availableSpan: 1_000)
        let committed = try bridge.commitDividerDrag()
        try require(committed?.cause == .dividerCommit, "pointer commit cause is incorrect")
        try require(committed?.layoutRevision == 2, "pointer commit revision is incorrect")
        try require(
            committed?.affectedTerminalIDs == ["terminal-a", "terminal-b"],
            "pointer commit affected-terminal projection is incorrect"
        )
        snapshot = try bridge.snapshot()
        try require(snapshot.leaves[0].width == 600_000, "committed pointer ratio was not projected")
        try require(snapshot.leaves[1].width == 400_000, "committed second pane ratio is incorrect")

        let keyboard = try bridge.resizeDividerFromKeyboard(
            dividerNodeID: divider,
            deltaBasisPoints: 500
        )
        try require(keyboard?.cause == .keyboard, "keyboard resize cause is incorrect")
        try require(keyboard?.layoutRevision == 3, "keyboard resize revision is incorrect")
        try require(
            keyboard?.affectedTerminalIDs == ["terminal-a", "terminal-b"],
            "keyboard affected-terminal projection is incorrect"
        )

        try bridge.close(terminalID: "terminal-b")
        snapshot = try bridge.snapshot()
        try require(snapshot.revision == 4, "close must advance revision once")
        try require(snapshot.focusedTerminalID == "terminal-a", "close did not repair focus")
        try require(snapshot.leaves.count == 1, "close did not collapse the tree")
        try require(snapshot.leaves[0].width == 1_000_000, "collapsed tree does not fill layout")
    }

    private static func validateRAIIReleasePath() throws {
        for index in 0..<32 {
            let bridge = try TerminalSplitLayoutBridge(initialTerminalID: "raii-\(index)")
            let snapshot = try bridge.snapshot()
            try require(snapshot.leaves.count == 1, "RAII fixture owner is unusable")
        }
    }

    private static func validateFourLeafRecursiveOwner() throws {
        let bridge = try TerminalSplitLayoutBridge(initialTerminalID: "recursive-a")
        let root = try bridge.splitFocused(axis: .leftRight, newTerminalID: "recursive-b")
        let nested = try bridge.splitFocused(axis: .topBottom, newTerminalID: "recursive-c")
        _ = try bridge.splitFocused(axis: .leftRight, newTerminalID: "recursive-d")
        var snapshot = try bridge.snapshot()
        try require(snapshot.leaves.count == 4, "recursive owner did not reach four leaves")
        let canSplitFifth = try bridge.canSplitFocused()
        try require(!canSplitFifth, "production cap admitted a fifth leaf")
        try requireFFIError(.limitExceeded, {
            _ = try bridge.splitFocused(axis: .topBottom, newTerminalID: "recursive-e")
        }, "fifth production leaf")

        _ = try bridge.resizeDividerFromKeyboard(
            dividerNodeID: root,
            deltaBasisPoints: 2_000
        )
        _ = try bridge.resizeDividerFromKeyboard(
            dividerNodeID: nested,
            deltaBasisPoints: -1_500
        )
        let revision = try bridge.snapshot().revision
        let intent = try bridge.equalize()
        try require(intent?.cause == .equalize, "equalize cause was not preserved across FFI")
        try require(intent?.layoutRevision == revision + 1, "equalize did not advance exactly once")
        try require(intent?.affectedTerminalIDs.count == 4, "equalize did not cover all four PTYs")
        let redundantEqualize = try bridge.equalize()
        try require(redundantEqualize == nil, "already equal recursive tree emitted resize work")
        snapshot = try bridge.snapshot()
        try require(snapshot.leaves.count == 4, "equalize changed recursive cardinality")

        try bridge.close(terminalID: "recursive-c")
        snapshot = try bridge.snapshot()
        try require(snapshot.leaves.count == 3, "recursive close did not collapse one parent")
    }
}
