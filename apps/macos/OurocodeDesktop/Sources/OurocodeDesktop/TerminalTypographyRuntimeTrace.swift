#if OUROCODE_GHOSTTY_METAL_SURFACE
import Foundation
import os

/// Debug-only, bounded trace for the typography/PTY resize transaction. It is
/// intentionally compiled out of release builds and contains geometry only.
enum TerminalTypographyRuntimeTrace {
    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.ourolabs.ourocode",
        category: "terminal-typography"
    )
    private static let lock = NSLock()
    private static var entries: [String] = []
    private static let maximumEntries = 64
    #endif

    static func record(_ stage: String, _ details: @autoclosure () -> String) {
        #if DEBUG
        let entry = "\(stage) \(details())"
        lock.lock()
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        lock.unlock()
        logger.debug("Ourocode typography trace: \(entry, privacy: .public)")
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
