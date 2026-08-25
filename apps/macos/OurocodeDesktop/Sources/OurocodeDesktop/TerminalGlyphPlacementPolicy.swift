import Foundation

struct TerminalGlyphPlacement: Equatable {
    let horizontalScale: CGFloat
    let originX: CGFloat
}

enum TerminalGlyphPlacementPolicy {
    /// Fallback CJK faces are often visually narrower than two terminal cells.
    /// Preserve the grid's authoritative width while fitting the raster inside
    /// that span, so Hangul does not look like one extra blank cell follows
    /// every syllable.
    static func resolve(
        lineWidth: CGFloat,
        tileWidth: CGFloat,
        columns: Int
    ) -> TerminalGlyphPlacement {
        guard lineWidth > 0, tileWidth > 0 else {
            return TerminalGlyphPlacement(horizontalScale: 1, originX: 0)
        }
        guard columns > 1 else {
            return TerminalGlyphPlacement(
                horizontalScale: 1,
                originX: max(0, (tileWidth - lineWidth) * 0.5)
            )
        }
        let targetWidth = max(lineWidth, tileWidth * 0.9)
        let scale = min(1.35, max(1, targetWidth / lineWidth))
        let renderedWidth = lineWidth * scale
        return TerminalGlyphPlacement(
            horizontalScale: scale,
            originX: max(0, (tileWidth - renderedWidth) * 0.5)
        )
    }
}
