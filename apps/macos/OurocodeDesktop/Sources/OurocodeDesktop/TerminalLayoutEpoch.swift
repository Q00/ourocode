import Dispatch

/// Produces a resize generation that remains monotonic across UI relaunches.
///
/// Older input-v2 brokers did not expose their current layout epoch in the
/// terminal summary. Using system uptime as a floor lets a newly attached app
/// safely advance an existing broker-owned PTY without killing or recreating
/// that session. The explicit `current` successor still handles repeated
/// resizes within one attachment.
enum TerminalLayoutEpoch {
    static func next(
        after current: UInt64,
        monotonicNow: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64? {
        let successor = current.addingReportingOverflow(1)
        guard !successor.overflow else { return nil }
        return max(successor.partialValue, max(1, monotonicNow))
    }
}
