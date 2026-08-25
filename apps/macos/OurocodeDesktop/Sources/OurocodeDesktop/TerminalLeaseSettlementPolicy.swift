import Foundation

enum TerminalLeaseSettlementPolicy {
    /// A pending candidate supersedes the old presentation regardless of
    /// whether that old Metal lease was consumed or retained for retry.
    static func shouldResumePendingCommit(hasPendingCommit: Bool) -> Bool {
        hasPendingCommit
    }
}
