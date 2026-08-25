import Foundation

/// Pure guard for destructive pane cleanup. A renderer detach only releases
/// an input/view lease; the broker-owned PTY remains alive until terminate is
/// acknowledged. Keep the destructive target testable and distinct from every
/// survivor before the host asks the broker to reap it.
enum TerminalPaneTerminationPolicy {
    static func terminationTarget(
        removedTerminalID: String,
        survivingTerminalIDs: Set<String>,
        detachReceiptReceived: Bool,
        layoutRemovalCommitted: Bool
    ) -> String? {
        guard !removedTerminalID.isEmpty,
              detachReceiptReceived,
              layoutRemovalCommitted,
              !survivingTerminalIDs.contains(removedTerminalID)
        else { return nil }
        return removedTerminalID
    }
}
