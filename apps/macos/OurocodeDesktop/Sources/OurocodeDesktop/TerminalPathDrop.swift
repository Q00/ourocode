import Foundation

/// Converts Finder file URLs into shell input without ever executing it.
/// Keeping this pure makes the security boundary easy to test: only local file
/// URLs are accepted and every path is single-quoted for POSIX shells.
enum TerminalPathDrop {
    static func shellInput(for paths: [URL]) -> String? {
        let local = paths.filter { $0.isFileURL && !$0.path.isEmpty }
        guard !local.isEmpty else { return nil }
        let escaped = local.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return escaped.joined(separator: " ") + " "
    }
}
