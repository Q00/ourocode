@main
enum TerminalTabFocusRestorationFixture {
    static func main() {
        // Closing a tab before the focused tab changes indices but not identity.
        let afterPrecedingClose = TerminalTabFocusRestoration.target(
            focusedID: "tab-c",
            liveIDs: ["tab-b", "tab-c"],
            preserve: true,
            requestGeneration: 4,
            currentGeneration: 4
        )
        precondition(afterPrecedingClose == "tab-c")

        // A rapid adjacent selection creates a newer projection. The queued
        // restoration from the older one must not take first responder back.
        let staleRapidSelection = TerminalTabFocusRestoration.target(
            focusedID: "tab-b",
            liveIDs: ["tab-b", "tab-c"],
            preserve: true,
            requestGeneration: 4,
            currentGeneration: 5
        )
        precondition(staleRapidSelection == nil)

        // An explicit selection owns focus even within the current generation.
        let explicitDestination = TerminalTabFocusRestoration.target(
            focusedID: "tab-b",
            liveIDs: ["tab-b", "tab-c"],
            preserve: false,
            requestGeneration: 5,
            currentGeneration: 5
        )
        precondition(explicitDestination == nil)

        // Closing the focused tab has no semantic element to restore.
        let removedFocusedTab = TerminalTabFocusRestoration.target(
            focusedID: "tab-a",
            liveIDs: ["tab-b", "tab-c"],
            preserve: true,
            requestGeneration: 6,
            currentGeneration: 6
        )
        precondition(removedFocusedTab == nil)

        print("PASS: tab focus restoration is identity- and generation-safe")
    }
}
