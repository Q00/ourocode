import Foundation

/// User-facing copy for terminal engine and startup-failure states.
///
/// Two rules come from the Rams hierarchy audit (`qa-evidence/
/// rams-01-hierarchy-audit-20260816.md`, P0 2):
///
/// 1. A headline names what the person lost and what they can do. It never
///    makes them parse an internal socket path, helper name, or engine pin.
/// 2. The exact technical cause stays reachable — tooltip, accessibility
///    help, or copyable diagnostics — so it is demoted, never destroyed.
///
/// The status vocabulary is deliberately plain. `Bootstrap adapter`,
/// `ANSI viewport recovery`, and `fixture:vt100-0.15.2` describe the repo's
/// engine lanes, not anything a person using a terminal chose or can act on.
enum TerminalBrokerPresentationPolicy {
    struct Status: Equatable {
        /// Short chrome label. Stays honest about degraded capability without
        /// spending permanent attention on internal lane names.
        let label: String
        /// Tooltip and accessibility help. Carries the concrete limitation.
        let help: String
    }

    /// The broker replayed through the bootstrap `vt100` lane rather than the
    /// audited Ghostty engine. This is a real capability difference, so it
    /// stays visible — but as a consequence, not as a lane identifier.
    static let compatibilityEngine = Status(
        label: "Limited terminal engine",
        help: """
            This session runs Ourocode's fallback terminal engine. Text, colors, \
            and commands work. Inline graphics and some advanced terminal \
            features are unavailable, and crash recovery is less exact than the \
            full engine. Technical detail: bootstrap ANSI replay adapter, \
            fixture:vt100-0.15.2.
            """
    )

    /// No terminal at all. The person cannot work, so the copy leads with the
    /// recovery action rather than the transport that failed.
    static let offline = Status(
        label: "Terminal unavailable",
        help: "Ourocode could not start a terminal. Choose Try Again to retry."
    )

    static let failureHeadline = "Ourocode could not start a terminal"

    static let failureExplanation = """
        The background service that runs your shell did not start. Your saved \
        sessions are not lost. You can try again, or copy the technical details \
        to share when reporting this.
        """

    static let retryButtonTitle = "Try Again"
    static let diagnosticsButtonTitle = "Copy Details"
    static let dismissButtonTitle = "Continue Without Terminal"

    /// The full engine did not start, but a working limited engine is
    /// available. This is a real capability tradeoff, so the person chooses —
    /// stated as consequences rather than as internal lane names.
    static let degradedChoiceHeadline = "Start with the limited terminal engine?"

    static let degradedChoiceExplanation = """
        The full terminal engine did not start. You can keep trying, or start \
        now with the limited engine: text, colors, and commands work, but \
        inline graphics are unavailable and crash recovery is less exact.
        """

    static let useLimitedEngineButtonTitle = "Use Limited Engine"
    static let keepTryingButtonTitle = "Keep Trying"

    /// Chrome status while the full engine is still being retried. The exact
    /// cause is demoted into help, never promoted into the label.
    static func retrying(reason: String) -> Status {
        Status(
            label: "Reconnecting…",
            help: "Ourocode is still trying to start the full terminal engine. Technical detail: \(reason)"
        )
    }

    /// Copyable diagnostics. This is the one place an internal path belongs:
    /// the person asked for it, and it goes to the pasteboard, not a headline.
    static func diagnostics(
        reason: String,
        socketPath: String,
        helperName: String
    ) -> String {
        """
        Ourocode terminal startup failure
        Reason: \(reason)
        Broker socket: \(socketPath)
        Broker helper: \(helperName)
        """
    }

    /// A headline must never leak internal plumbing. Verified by fixture so a
    /// later copy edit cannot quietly reintroduce a raw path or lane name.
    static func isPresentableHeadline(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lowered = value.lowercased()
        // Fragments that are internal wherever they appear.
        let plumbingFragments = ["/", ".sock", "fixture:", "vt100", "libghostty"]
        if plumbingFragments.contains(where: lowered.contains) { return false }
        // Lane, engine, and transport vocabulary, matched as whole words.
        // Substring matching would reject ordinary copy for merely containing
        // these letters — "expansion" contains "ansi".
        let internalWords: Set<String> = [
            "bootstrap", "ansi", "broker", "ghostty", "adapter",
            "pty", "socket", "helper", "daemon", "metal",
        ]
        let words = lowered.split { !$0.isLetter && !$0.isNumber }
        return !words.contains { internalWords.contains(String($0)) }
    }
}
