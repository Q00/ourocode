import Foundation

/// Keeps high session counts from turning the title bar into a dashboard.
/// Nearby tabs preserve spatial context; the searchable all-tabs picker is the
/// complete index and remains visible whenever this projection is bounded.
enum TerminalTabWindow {
    static let maximumVisible = 5

    static func indices(total: Int, selected: Int) -> [Int] {
        guard total > 0 else { return [] }
        guard total > maximumVisible else { return Array(0..<total) }
        let safeSelected = min(max(0, selected), total - 1)
        let half = maximumVisible / 2
        let start = min(max(0, safeSelected - half), total - maximumVisible)
        return Array(start..<(start + maximumVisible))
    }
}
