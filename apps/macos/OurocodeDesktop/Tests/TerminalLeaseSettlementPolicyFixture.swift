import Foundation

private enum LeaseDisposition: Equatable {
    case consumed
    case retry
}

private final class CoordinatorModel {
    var frameLeaseOutstanding = true
    var hasPendingCommit = true
    var retryCancelCount = 0
    var commitCount = 0

    func settle(_ disposition: LeaseDisposition) {
        frameLeaseOutstanding = false
        if TerminalLeaseSettlementPolicy.shouldResumePendingCommit(
            hasPendingCommit: hasPendingCommit
        ) {
            performPendingCommit(after: disposition)
        }
    }

    private func performPendingCommit(after disposition: LeaseDisposition) {
        precondition(!frameLeaseOutstanding)
        if disposition == .retry { retryCancelCount += 1 }
        hasPendingCommit = false
        commitCount += 1
    }
}

@main
private enum TerminalLeaseSettlementPolicyFixture {
    static func main() {
        for disposition in [LeaseDisposition.consumed, .retry] {
            let model = CoordinatorModel()
            model.settle(disposition)
            precondition(model.commitCount == 1)
            precondition(model.retryCancelCount == (disposition == .retry ? 1 : 0))
        }

        let idle = CoordinatorModel()
        idle.hasPendingCommit = false
        idle.settle(.retry)
        precondition(idle.commitCount == 0)
        precondition(idle.retryCancelCount == 0)

        print("PASS: consumed and retry lease settlements both resume pending cutover")
    }
}
