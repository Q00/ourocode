#if OUROCODE_GHOSTTY_METAL_SURFACE
import Foundation
import os

/// Debug-only, bounded trace for the split-pane recovery/presentation fence.
/// It deliberately records lifecycle and view geometry only: terminal output,
/// commands, paths, and full broker identifiers never enter the trace.
enum TerminalPaneRuntimeTrace {
    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.ourolabs.ourocode",
        category: "terminal-pane-runtime"
    )
    private static let lock = NSLock()
    private static var entries: [String] = []
    private static let maximumEntries = 96
    #endif

    static func record(_ stage: String, _ details: @autoclosure () -> String = "") {
        #if DEBUG
        let suffix = details()
        let entry = suffix.isEmpty ? stage : "\(stage) \(suffix)"
        lock.lock()
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        lock.unlock()
        // This logger exists only in DEBUG builds and carries lifecycle plus
        // view geometry, never terminal content. Notice-level persistence is
        // intentional so an acting QA run can recover the exact stalled fence
        // with `log show` after the UI stops advancing.
        logger.notice("Ourocode pane trace: \(entry, privacy: .public)")
        #endif
    }

    static func snapshot() -> [String] {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        return entries
        #else
        return []
        #endif
    }
}
#endif
