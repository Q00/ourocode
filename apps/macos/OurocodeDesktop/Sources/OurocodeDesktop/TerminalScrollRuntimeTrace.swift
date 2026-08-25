#if OUROCODE_GHOSTTY_METAL_SURFACE
  import Foundation

  /// Debug-only, bounded evidence for the native scroll path. Release builds
  /// retain no entries; development builds keep only the newest 32 stages.
  enum TerminalScrollRuntimeTrace {
    #if DEBUG
      private static let lock = NSLock()
      private static var entries: [String] = []
      private static let maximumEntries = 32
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
        NSLog("Ourocode scroll trace: %@", entry)
        FileHandle.standardError.write(Data("Ourocode scroll trace: \(entry)\n".utf8))
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
