import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum TerminalPrimaryPanePromotionPolicyFixture {
    static func main() {
        let plan = TerminalPrimaryPanePromotionPolicy.plan(
            orderedTerminalIDs: ["primary", "right", "down"],
            focusedTerminalID: "primary",
            primaryTerminalID: "primary",
            layoutRevision: 7
        )
        require(plan?.promotedTerminalID == "right", "visual successor was not deterministic")
        guard let plan else { exit(1) }
        require(TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
            plan,
            currentPrimaryTerminalID: "primary",
            currentLayoutRevision: 7,
            oldAttachmentMatches: true,
            promotedAttachmentMatches: true,
            detachReceiptReceived: true
        ), "valid ordered detach commit was rejected")
        require(!TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
            plan,
            currentPrimaryTerminalID: "primary",
            currentLayoutRevision: 8,
            oldAttachmentMatches: true,
            promotedAttachmentMatches: true,
            detachReceiptReceived: true
        ), "stale layout callback was accepted")
        require(!TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
            plan,
            currentPrimaryTerminalID: "primary",
            currentLayoutRevision: 7,
            oldAttachmentMatches: false,
            promotedAttachmentMatches: true,
            detachReceiptReceived: true
        ), "replaced old lease was accepted")
        require(!TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
            plan,
            currentPrimaryTerminalID: "primary",
            currentLayoutRevision: 7,
            oldAttachmentMatches: true,
            promotedAttachmentMatches: false,
            detachReceiptReceived: true
        ), "replaced survivor lease was accepted")
        require(!TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
            plan,
            currentPrimaryTerminalID: "primary",
            currentLayoutRevision: 7,
            oldAttachmentMatches: true,
            promotedAttachmentMatches: true,
            detachReceiptReceived: false
        ), "promotion committed before the detach receipt")
        require(TerminalPrimaryPanePromotionPolicy.plan(
            orderedTerminalIDs: ["primary"],
            focusedTerminalID: "primary",
            primaryTerminalID: "primary",
            layoutRevision: 1
        ) == nil, "last pane produced a promotion plan")
        print("PASS: primary promotion requires exact leases, current layout CAS, and ordered detach receipt")
    }
}
