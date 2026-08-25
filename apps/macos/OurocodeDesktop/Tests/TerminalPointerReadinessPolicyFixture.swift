import Foundation

@main
enum TerminalPointerReadinessPolicyFixture {
    static func main() {
        require(
            TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: false,
                barrierPrepared: false,
                barrierAborted: false,
                expectedLayoutEpoch: nil,
                activeLayoutEpoch: 7,
                repairPending: false
            ),
            "missing geometry without a resize barrier did not request repair"
        )
        require(
            TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: true,
                barrierPrepared: true,
                barrierAborted: false,
                expectedLayoutEpoch: 8,
                activeLayoutEpoch: 8,
                repairPending: false
            ),
            "an applied resize barrier could not repair a missed geometry ACK"
        )
        require(
            !TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: true,
                barrierPrepared: true,
                barrierAborted: false,
                expectedLayoutEpoch: 8,
                activeLayoutEpoch: 7,
                repairPending: false
            ),
            "repair opened before the expected layout became active"
        )
        require(
            !TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: true,
                barrierPrepared: false,
                barrierAborted: false,
                expectedLayoutEpoch: 8,
                activeLayoutEpoch: 8,
                repairPending: false
            ),
            "an unprepared barrier was repairable"
        )
        require(
            !TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: true,
                barrierPrepared: true,
                barrierAborted: true,
                expectedLayoutEpoch: nil,
                activeLayoutEpoch: 8,
                repairPending: false
            ),
            "an aborted barrier reopened the new coordinate space"
        )
        require(
            !TerminalPointerReadinessPolicy.shouldRepair(
                barrierPresent: true,
                barrierPrepared: true,
                barrierAborted: false,
                expectedLayoutEpoch: 8,
                activeLayoutEpoch: 8,
                repairPending: true
            ),
            "duplicate readiness repair was admitted"
        )
        print("PASS: pointer geometry repair is level-triggered only at an applied layout")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
