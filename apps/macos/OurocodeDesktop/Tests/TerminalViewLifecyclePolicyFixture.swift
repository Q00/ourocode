import Foundation

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard condition() else {
        fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
        exit(1)
    }
}

private func snapshot(
    identity: Bool = true,
    attachment: Bool = false,
    preparation: Bool = false,
    creating: Bool = false,
    unknownCreate: Bool = false
) -> TerminalViewLifecycleSnapshot {
    TerminalViewLifecycleSnapshot(
        hasStableTerminalIdentity: identity,
        hasAttachment: attachment,
        attachmentPreparationInFlight: preparation,
        creationInFlight: creating,
        creationOutcomeUnknown: unknownCreate
    )
}

@main
private enum TerminalViewLifecyclePolicyFixture {
    static func main() {
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .closeView,
                snapshot: snapshot(attachment: true)
            ) == .detachAttachment,
            "close view must detach an exact live attachment first"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .closeView,
                snapshot: snapshot()
            ) == .removeView,
            "close view must not terminate a detached broker terminal"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .terminateSession,
                snapshot: snapshot(attachment: true)
            ) == .detachAttachment,
            "termination must cross detach before destructive mutation"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .terminateSession,
                snapshot: snapshot()
            ) == .terminateSession,
            "confirmed termination must target the stable broker identity"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .closeView,
                snapshot: snapshot(identity: false, creating: true)
            ) == .waitForStableIdentity,
            "close during create must preserve the unknown terminal outcome"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .terminateSession,
                snapshot: snapshot(identity: false, unknownCreate: true)
            ) == .waitForStableIdentity,
            "terminate during ambiguous create must reconcile before acting"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .closeView,
                snapshot: snapshot(preparation: true)
            ) == .cancelAttachmentPreparation,
            "close during recovery must cancel and await the recovery callback"
        )
        require(
            TerminalViewLifecyclePolicy.nextAction(
                disposition: .terminateSession,
                snapshot: snapshot(identity: false)
            ) == .removeView,
            "termination cannot invent a target when create proved absent"
        )
        print("PASS: close-view preserves PTY; terminate remains explicit and recovery-safe")
    }
}
