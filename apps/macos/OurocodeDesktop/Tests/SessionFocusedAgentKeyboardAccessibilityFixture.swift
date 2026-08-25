import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: (message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionFocusedAgentKeyboardAccessibilityFixture {
    static func main() {
        let noLink = SessionFocusedAgentComposerPolicy.resolve(
            hasFocusedBinding: false,
            focusedIdentityMatchesTarget: false,
            advertisesAfterTurn: false,
            projectionTrusted: false,
            authenticatedTransportReady: false
        )
        require(
            noLink == .unavailable(SessionFocusedAgentComposerPolicy.noLinkedAgent),
            "unbound pane keyboard action was silent"
        )

        let ready = SessionFocusedAgentComposerPolicy.resolve(
            hasFocusedBinding: true,
            focusedIdentityMatchesTarget: true,
            advertisesAfterTurn: true,
            projectionTrusted: true,
            authenticatedTransportReady: true
        )
        require(ready == .focusComposer, "fully verified exact pane could not focus composer")

        let mismatched = SessionFocusedAgentComposerPolicy.resolve(
            hasFocusedBinding: true,
            focusedIdentityMatchesTarget: false,
            advertisesAfterTurn: true,
            projectionTrusted: true,
            authenticatedTransportReady: true
        )
        require(
            mismatched != .focusComposer,
            "keyboard action fell back to a wrong or global composer"
        )

        print("PASS: focused-agent keyboard action has explicit AX-safe success and refusal outcomes")
    }
}
