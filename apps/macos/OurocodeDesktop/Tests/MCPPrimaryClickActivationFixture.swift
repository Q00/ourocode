import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private struct EventHarness {
    var activeNodeID: String?
    var inspectionApplications = 0
    var primaryActions = 0
    var detailPresentations = 0

    mutating func selectionDidChange(to nodeID: String) {
        inspectIfNeeded(nodeID)
    }

    mutating func primaryClick(
        clickedNodeID: String,
        selectedRow: Int,
        clickedRow: Int,
        detailRow: Bool,
        hasPrimaryTerminalAction: Bool = false,
        selectionCallbackIsSynchronous: Bool
    ) {
        if MCPPrimaryClickActivation.shouldRequestSelection(
            selectedRow: selectedRow,
            clickedRow: clickedRow
        ), selectionCallbackIsSynchronous {
            selectionDidChange(to: clickedNodeID)
        }
        inspectIfNeeded(clickedNodeID)
        if hasPrimaryTerminalAction {
            primaryActions += 1
        }
        if MCPPrimaryClickActivation.shouldPresentDetail(
            isDetailRow: detailRow,
            hasPrimaryTerminalAction: hasPrimaryTerminalAction
        ) {
            detailPresentations += 1
        }
        if !selectionCallbackIsSynchronous {
            // Models the delayed AppKit selection notification arriving after
            // the outline action has already presented the detail.
            selectionDidChange(to: clickedNodeID)
        }
    }

    mutating func pressReturn(hasPrimaryTerminalAction: Bool) {
        if activeNodeID != nil, hasPrimaryTerminalAction {
            primaryActions += 1
        }
    }

    mutating func pressSpace() {
        if activeNodeID != nil {
            detailPresentations += 1
        }
    }

    private mutating func inspectIfNeeded(_ nodeID: String) {
        guard MCPPrimaryClickActivation.shouldApplySelection(
            activeNodeID: activeNodeID,
            incomingNodeID: nodeID
        ) else { return }
        activeNodeID = nodeID
        inspectionApplications += 1
    }
}

@main
private enum MCPPrimaryClickActivationFixture {
    static func main() {
        require(
            MCPPrimaryClickActivation.keyAction(
                keyCode: 36,
                charactersIgnoringModifiers: "\r",
                hasActionModifier: false
            ) == .primaryAction,
            "Return did not map to the primary action"
        )
        require(
            MCPPrimaryClickActivation.keyAction(
                keyCode: 76,
                charactersIgnoringModifiers: "\r",
                hasActionModifier: false
            ) == .primaryAction,
            "keypad Enter did not map to the primary action"
        )
        require(
            MCPPrimaryClickActivation.keyAction(
                keyCode: 36,
                charactersIgnoringModifiers: "\r",
                hasActionModifier: true
            ) == .system,
            "modified Return bypassed the system key path"
        )
        require(
            MCPPrimaryClickActivation.keyAction(
                keyCode: 49,
                charactersIgnoringModifiers: " ",
                hasActionModifier: false
            ) == .detail,
            "Space did not remain the detail action"
        )
        require(
            MCPPrimaryClickActivation.keyAction(
                keyCode: 49,
                charactersIgnoringModifiers: " ",
                hasActionModifier: true
            ) == .system,
            "modified Space bypassed the system key path"
        )

        var synchronous = EventHarness()
        synchronous.primaryClick(
            clickedNodeID: "session:one",
            selectedRow: -1,
            clickedRow: 7,
            detailRow: true,
            selectionCallbackIsSynchronous: true
        )
        require(synchronous.activeNodeID == "session:one", "first click did not activate the leaf")
        require(synchronous.inspectionApplications == 1, "synchronous selection inspected more than once")
        require(synchronous.primaryActions == 0, "history click triggered terminal entry")
        require(synchronous.detailPresentations == 1, "first click did not present detail exactly once")

        var delayed = EventHarness()
        delayed.primaryClick(
            clickedNodeID: "session:two",
            selectedRow: -1,
            clickedRow: 9,
            detailRow: true,
            selectionCallbackIsSynchronous: false
        )
        require(delayed.activeNodeID == "session:two", "delayed selection did not activate the leaf")
        require(delayed.inspectionApplications == 1, "delayed delegate callback repeated inspection")
        require(delayed.detailPresentations == 1, "delayed ordering presented detail more than once")

        delayed.primaryClick(
            clickedNodeID: "session:two",
            selectedRow: 9,
            clickedRow: 9,
            detailRow: true,
            selectionCallbackIsSynchronous: true
        )
        require(delayed.inspectionApplications == 1, "selected-row click repeated inspection")
        require(delayed.detailPresentations == 2, "selected-row click did not present one new detail")

        var terminal = EventHarness(activeNodeID: "session:terminal")
        terminal.primaryClick(
            clickedNodeID: "session:terminal",
            selectedRow: 11,
            clickedRow: 11,
            detailRow: true,
            hasPrimaryTerminalAction: true,
            selectionCallbackIsSynchronous: true
        )
        require(terminal.detailPresentations == 0, "terminal entry was obscured by a detail popover")
        require(terminal.primaryActions == 1, "an already-selected terminal row did not activate")

        var keyboard = EventHarness()
        keyboard.selectionDidChange(to: "session:keyboard")
        require(keyboard.inspectionApplications == 1, "keyboard selection was not inspected")
        require(keyboard.primaryActions == 0, "keyboard selection triggered terminal entry")
        require(keyboard.detailPresentations == 0, "keyboard selection opened a pointer-only popover")
        keyboard.pressReturn(hasPrimaryTerminalAction: true)
        require(keyboard.primaryActions == 1, "Return did not execute the selected terminal action")
        require(keyboard.detailPresentations == 0, "Return opened details instead of the terminal")
        keyboard.pressSpace()
        require(keyboard.detailPresentations == 1, "Space did not open session details")

        var disclosure = EventHarness()
        disclosure.primaryClick(
            clickedNodeID: "collection:sessions",
            selectedRow: -1,
            clickedRow: 3,
            detailRow: false,
            selectionCallbackIsSynchronous: true
        )
        require(disclosure.inspectionApplications == 1, "disclosure row did not preserve selection")
        require(disclosure.detailPresentations == 0, "disclosure row unexpectedly opened detail")

        print("PASS: primary clicks route terminal entry directly and keep Space for session detail")
    }
}
