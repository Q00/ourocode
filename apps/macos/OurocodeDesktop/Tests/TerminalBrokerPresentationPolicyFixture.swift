import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum TerminalBrokerPresentationPolicyFixture {
    static func main() {
        let policy = TerminalBrokerPresentationPolicy.self

        // Rams P0 2: no headline or chrome label may make a person read
        // internal plumbing.
        require(
            policy.isPresentableHeadline(policy.failureHeadline),
            "the startup-failure headline leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.failureExplanation),
            "the startup-failure explanation leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.offline.label),
            "the offline chrome label leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.compatibilityEngine.label),
            "the limited-engine chrome label leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.degradedChoiceHeadline),
            "the degraded-engine headline leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.degradedChoiceExplanation),
            "the degraded-engine explanation leaked internal plumbing"
        )
        require(
            policy.isPresentableHeadline(policy.retrying(reason: "connect failed").label),
            "the retrying chrome label leaked internal plumbing"
        )

        // The detector must actually reject the strings that shipped before,
        // or the assertions above prove nothing.
        require(
            !policy.isPresentableHeadline("Bootstrap · ANSI recovery"),
            "the previous lane-name label was accepted as presentable"
        )
        require(
            !policy.isPresentableHeadline("Ghostty surface · offline"),
            "the previous engine-name label was accepted as presentable"
        )
        require(
            !policy.isPresentableHeadline("Bootstrap adapter · fixture:vt100-0.15.2"),
            "an engine pin was accepted as presentable"
        )
        require(
            !policy.isPresentableHeadline(
                "Unable to connect to the terminal broker at /Users/x/broker-v4.sock."),
            "a raw socket path was accepted as presentable"
        )
        require(
            !policy.isPresentableHeadline(
                "Broker v4 did not start: Unable to connect at /Users/x/b.sock"),
            "the previous compatibility-mode explanation was accepted as presentable"
        )
        require(
            !policy.isPresentableHeadline("Broker v4 · retrying"),
            "the previous retrying label was accepted as presentable"
        )
        require(!policy.isPresentableHeadline(""), "an empty headline was accepted")

        // Ordinary copy must survive the word filter. Substring matching would
        // reject this for containing "ansi" inside "expansion".
        require(
            policy.isPresentableHeadline("Terminal expansion finished"),
            "the word filter rejected ordinary copy containing an internal substring"
        )

        // Demoted, never destroyed: the exact cause stays reachable in help.
        require(
            policy.compatibilityEngine.help.contains("fixture:vt100-0.15.2"),
            "the limited-engine help dropped the exact engine pin"
        )
        require(
            policy.compatibilityEngine.help != policy.compatibilityEngine.label,
            "the limited-engine status carried no additional explanation"
        )
        require(
            policy.retrying(reason: "connect failed at /tmp/b.sock").help
                .contains("/tmp/b.sock"),
            "the retrying help dropped the exact technical cause"
        )

        // Copyable diagnostics are the one place a path belongs, because the
        // person asked for it and it goes to the pasteboard.
        let diagnostics = policy.diagnostics(
            reason: "connect failed",
            socketPath: "/Users/x/Library/Application Support/Ourocode/broker-v4.sock",
            helperName: "ouro-broker-v4"
        )
        require(diagnostics.contains("connect failed"), "diagnostics dropped the reason")
        require(diagnostics.contains("broker-v4.sock"), "diagnostics dropped the socket path")
        require(diagnostics.contains("ouro-broker-v4"), "diagnostics dropped the helper name")

        // Recovery actions must be nameable and distinct, or an alert has no
        // clear primary action.
        let recoveryActions = [
            policy.retryButtonTitle,
            policy.diagnosticsButtonTitle,
            policy.dismissButtonTitle,
        ]
        require(
            Set(recoveryActions).count == recoveryActions.count
                && recoveryActions.allSatisfy { !$0.isEmpty },
            "recovery actions were duplicated or empty"
        )
        let degradedActions = [
            policy.keepTryingButtonTitle,
            policy.useLimitedEngineButtonTitle,
        ]
        require(
            Set(degradedActions).count == degradedActions.count
                && degradedActions.allSatisfy { !$0.isEmpty },
            "degraded-engine choice actions were duplicated or empty"
        )

        print("PASS: terminal broker copy keeps plumbing out of headlines and recovery reachable")
    }
}
