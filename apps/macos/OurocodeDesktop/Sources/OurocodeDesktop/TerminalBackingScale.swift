import AppKit

final class TerminalAppearanceTrackingView: NSView {
    var onAppearanceChange: (() -> Void)?
    var onBackingPropertiesChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingPropertiesChange?()
    }
}

/// Pixel geometry derived from the window's current backing scale.
///
/// Keeping this conversion in one value makes display moves deterministic:
/// the same point-sized terminal returns to the same pixel geometry after a
/// 1x -> 2x -> 1x transition.
struct TerminalBackingScaleGeometry: Equatable {
    let backingScale: CGFloat
    let cellWidthPixels: Int
    let cellHeightPixels: Int

    var cellSizeInPoints: NSSize {
        NSSize(
            width: CGFloat(cellWidthPixels) / backingScale,
            height: CGFloat(cellHeightPixels) / backingScale
        )
    }

    init(cellSize: NSSize, backingScale: CGFloat) {
        let normalizedScale = max(1, backingScale)
        self.backingScale = normalizedScale
        cellWidthPixels = Int((cellSize.width * normalizedScale).rounded(.up))
        cellHeightPixels = Int((cellSize.height * normalizedScale).rounded(.up))
    }
}
