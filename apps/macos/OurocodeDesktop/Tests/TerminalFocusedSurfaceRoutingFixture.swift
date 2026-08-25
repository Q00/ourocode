import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalFocusedSurfaceRoutingFixture {
    static func main() {
        let additional: Set<String> = ["split-a", "split-b"]
        require(
            TerminalFocusedSurfaceRouting.terminalID(
                primaryTerminalID: "primary",
                focusedTerminalID: "primary",
                availableAdditionalTerminalIDs: additional
            ) == "primary",
            "the primary pane did not retain terminal-wide commands"
        )
        require(
            TerminalFocusedSurfaceRouting.terminalID(
                primaryTerminalID: "primary",
                focusedTerminalID: "split-b",
                availableAdditionalTerminalIDs: additional
            ) == "split-b",
            "the focused split did not receive terminal-wide commands"
        )
        require(
            TerminalFocusedSurfaceRouting.terminalID(
                primaryTerminalID: "primary",
                focusedTerminalID: "stale-split",
                availableAdditionalTerminalIDs: additional
            ) == "primary",
            "a stale focused identity escaped the primary-pane fallback"
        )
        require(
            TerminalFocusedSurfaceRouting.terminalID(
                primaryTerminalID: "primary",
                focusedTerminalID: nil,
                availableAdditionalTerminalIDs: additional
            ) == "primary",
            "missing focus did not fall back to the primary pane"
        )
        require(
            TerminalFocusedSurfaceRouting.terminalID(
                primaryTerminalID: nil,
                focusedTerminalID: "split-a",
                availableAdditionalTerminalIDs: additional
            ) == nil,
            "routing invented a pane without a selected terminal tab"
        )
        print("PASS: terminal-wide commands resolve to the exact focused pane and fail closed")
    }
}
