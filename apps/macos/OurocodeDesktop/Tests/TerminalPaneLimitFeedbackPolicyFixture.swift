import AppKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum TerminalPaneLimitFeedbackPolicyFixture {
    static func main() {
        let policy = TerminalPaneLimitFeedbackPolicy.self
        require(policy.maximumPaneCount == 4, "production feedback cap drifted")
        require(policy.message == "Maximum 4 panes", "visible and AX copy drifted")
        require(!policy.shouldAnnounce(paneCount: 3, keyCode: 2, modifiers: [.command]), "valid fourth split was intercepted")
        require(policy.shouldAnnounce(paneCount: 4, keyCode: 2, modifiers: [.command]), "Command-D fifth split was silent")
        require(policy.shouldAnnounce(paneCount: 4, keyCode: 2, modifiers: [.command, .shift]), "Shift-Command-D fifth split was silent")
        require(!policy.shouldAnnounce(paneCount: 4, keyCode: 2, modifiers: [.command, .option]), "unrelated modifier chord was consumed")
        require(!policy.shouldAnnounce(paneCount: 4, keyCode: 1, modifiers: [.command]), "unrelated Command key was consumed")
        print("PASS: four-pane menu cap keeps exact split shortcuts audible and AX-visible")
    }
}
