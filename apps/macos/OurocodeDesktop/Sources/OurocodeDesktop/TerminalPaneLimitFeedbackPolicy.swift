import AppKit

/// Pure shortcut policy for the bounded production split surface. Native menu
/// items remain disabled at the cap; only their exact key equivalents are
/// consumed so keyboard users still receive visible and VoiceOver feedback.
enum TerminalPaneLimitFeedbackPolicy {
    static let maximumPaneCount = 4
    static let message = "Maximum 4 panes"

    static func shouldAnnounce(
        paneCount: Int,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard paneCount >= maximumPaneCount, keyCode == 2 else { return false }
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        return relevant == [.command] || relevant == [.command, .shift]
    }
}
