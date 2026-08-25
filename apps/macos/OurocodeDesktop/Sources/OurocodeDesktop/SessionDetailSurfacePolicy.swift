import CoreGraphics

/// Geometry for the session inspector. The navigator remains a compact
/// browsing surface; the detail inspector gets a readable, transient reading
/// surface only while it is open.
enum SessionDetailSurfacePolicy {
    // Session rows carry a title, one useful activity line, and an explicit
    // action affordance.  Keep enough width for all three so the navigator
    // scans like a familiar source list instead of a column of clipped IDs.
    static let browsingRailWidth: CGFloat = 304
    static let minimumReadingWidth: CGFloat = 420
    static let preferredReadingWidth: CGFloat = 448
    static let maximumReadingWidth: CGFloat = 480

    static func readingWidth(availableWindowWidth: CGFloat) -> CGFloat {
        guard availableWindowWidth.isFinite, availableWindowWidth > 0 else {
            return preferredReadingWidth
        }
        // Keep enough of the terminal visible on compact windows, while
        // avoiding a narrow inspector that forces every sentence to wrap.
        let proportional = availableWindowWidth * 0.44
        return min(maximumReadingWidth, max(minimumReadingWidth, proportional))
    }
}
