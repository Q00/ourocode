#if OUROCODE_GHOSTTY_METAL_SURFACE
import Foundation

/// Pure decision boundary for level-triggered pointer-geometry repair.
///
/// A resize barrier may request another geometry acknowledgement only after
/// the renderer has applied its exact expected layout epoch. Until then the
/// old and new coordinate spaces are intentionally both closed.
enum TerminalPointerReadinessPolicy {
    static func shouldRepair(
        barrierPresent: Bool,
        barrierPrepared: Bool,
        barrierAborted: Bool,
        expectedLayoutEpoch: UInt64?,
        activeLayoutEpoch: UInt64,
        repairPending: Bool
    ) -> Bool {
        guard !repairPending, activeLayoutEpoch > 0 else { return false }
        guard barrierPresent else { return true }
        return barrierPrepared
            && !barrierAborted
            && expectedLayoutEpoch == activeLayoutEpoch
    }
}
#endif
