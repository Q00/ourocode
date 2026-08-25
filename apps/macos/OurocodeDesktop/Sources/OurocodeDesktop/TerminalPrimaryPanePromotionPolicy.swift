import Foundation

struct TerminalPrimaryPanePromotionPlan: Equatable {
    let oldPrimaryTerminalID: String
    let promotedTerminalID: String
    let expectedLayoutRevision: UInt64
}

/// Pure CAS policy around the broker-owned attachment handoff. The host still
/// validates complete attachment tokens, but stale callback acceptance is
/// kept testable without constructing a PTY or Metal surface.
enum TerminalPrimaryPanePromotionPolicy {
    static func plan(
        orderedTerminalIDs: [String],
        focusedTerminalID: String,
        primaryTerminalID: String,
        layoutRevision: UInt64
    ) -> TerminalPrimaryPanePromotionPlan? {
        guard layoutRevision < UInt64.max,
              orderedTerminalIDs.count > 1,
              Set(orderedTerminalIDs).count == orderedTerminalIDs.count,
              focusedTerminalID == primaryTerminalID,
              let closedIndex = orderedTerminalIDs.firstIndex(of: primaryTerminalID)
        else { return nil }
        let survivors = orderedTerminalIDs.filter { $0 != primaryTerminalID }
        guard !survivors.isEmpty else { return nil }
        return TerminalPrimaryPanePromotionPlan(
            oldPrimaryTerminalID: primaryTerminalID,
            promotedTerminalID: survivors[min(closedIndex, survivors.count - 1)],
            expectedLayoutRevision: layoutRevision
        )
    }

    static func acceptsDetachedCommit(
        _ plan: TerminalPrimaryPanePromotionPlan,
        currentPrimaryTerminalID: String?,
        currentLayoutRevision: UInt64,
        oldAttachmentMatches: Bool,
        promotedAttachmentMatches: Bool,
        detachReceiptReceived: Bool
    ) -> Bool {
        detachReceiptReceived
            && oldAttachmentMatches
            && promotedAttachmentMatches
            && currentPrimaryTerminalID == plan.oldPrimaryTerminalID
            && currentLayoutRevision == plan.expectedLayoutRevision
    }
}
