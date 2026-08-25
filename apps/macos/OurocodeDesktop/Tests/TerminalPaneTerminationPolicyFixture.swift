import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum TerminalPaneTerminationPolicyFixture {
    static func main() {
        let survivors: Set<String> = ["promoted", "third"]
        require(TerminalPaneTerminationPolicy.terminationTarget(
            removedTerminalID: "old-primary",
            survivingTerminalIDs: survivors,
            detachReceiptReceived: true,
            layoutRemovalCommitted: true
        ) == "old-primary", "the exact removed pane was not selected for reaping")
        require(TerminalPaneTerminationPolicy.terminationTarget(
            removedTerminalID: "promoted",
            survivingTerminalIDs: survivors,
            detachReceiptReceived: true,
            layoutRemovalCommitted: true
        ) == nil, "a promoted survivor could be terminated")
        require(TerminalPaneTerminationPolicy.terminationTarget(
            removedTerminalID: "old-primary",
            survivingTerminalIDs: survivors,
            detachReceiptReceived: false,
            layoutRemovalCommitted: true
        ) == nil, "termination was allowed before the detach receipt")
        require(TerminalPaneTerminationPolicy.terminationTarget(
            removedTerminalID: "old-primary",
            survivingTerminalIDs: survivors,
            detachReceiptReceived: true,
            layoutRemovalCommitted: false
        ) == nil, "termination was allowed before the layout removal committed")
        print("PASS: pane termination targets only the detached, removed PTY and never a survivor")
    }
}
