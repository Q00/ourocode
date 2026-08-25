import AppKit

enum OuroTheme {
    // The terminal needs a real terminal palette. AppKit's text background is
    // intentionally brighter in Dark Mode and made the Metal surface read as
    // a grey inspector instead of a focused shell.
    static var canvas: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
                : NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)
        }
    }
    static var panel: NSColor { .windowBackgroundColor }
    static var railCanvas: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x20 / 255, green: 0x22 / 255, blue: 0x26 / 255, alpha: 1)
                : NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF6 / 255, alpha: 1)
        }
    }
    static var railSelection: NSColor {
        NSColor(name: nil) { appearance in
            let alpha: CGFloat
            if accessibility.increaseContrast {
                alpha = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.30 : 0.22
            } else {
                alpha = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.16 : 0.10
            }
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(alpha)
                : NSColor.black.withAlphaComponent(alpha)
        }
    }
    static var elevated: NSColor { .controlBackgroundColor }
    static var border: NSColor { .separatorColor }
    static var text: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255, alpha: 1)
                : NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255, alpha: 1)
        }
    }
    static var muted: NSColor { .secondaryLabelColor }
    static var tabText: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xB8 / 255, green: 0xB8 / 255, blue: 0xBA / 255, alpha: 1)
                : NSColor(srgbRed: 0x4F / 255, green: 0x4F / 255, blue: 0x54 / 255, alpha: 1)
        }
    }

    // Mint is deliberately reserved for verified live state and the cursor.
    static var mint: NSColor {
        accessibility.increaseContrast ? .keyboardFocusIndicatorColor : .systemMint
    }

    static var accessibility: Accessibility {
        let workspace = NSWorkspace.shared
        return Accessibility(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }

    struct Accessibility: Equatable {
        let reduceTransparency: Bool
        let increaseContrast: Bool
    }

    // Start from a comfortable reading size. Terminal chrome is secondary to
    // the shell, so the grid must not render smaller than the surrounding UI.
    private static let terminalFontSizeKey = "terminalFontSize"
    // Goose/Kaku both reinforce that a terminal is read for hours rather than
    // glanced at like dashboard chrome. 16pt keeps a generous Retina grid
    // while restoring at least twenty-four lines in the default window.
    static let defaultTerminalFontSize: CGFloat = 16
    static let minimumTerminalFontSize: CGFloat = 12
    static let maximumTerminalFontSize: CGFloat = 48

    static var terminalFontSize: CGFloat {
        let stored = CGFloat(UserDefaults.standard.double(forKey: terminalFontSizeKey))
        guard stored > 0 else { return defaultTerminalFontSize }
        return min(maximumTerminalFontSize, max(minimumTerminalFontSize, stored))
    }

    static func setTerminalFontSize(_ size: CGFloat) {
        let clamped = min(maximumTerminalFontSize, max(minimumTerminalFontSize, size))
        UserDefaults.standard.set(Double(clamped), forKey: terminalFontSizeKey)
    }

    static func resetTerminalFontSize() {
        UserDefaults.standard.removeObject(forKey: terminalFontSizeKey)
    }

    static var terminalCellSize: NSSize {
        terminalCellSize(fontSize: terminalFontSize)
    }

    static func terminalCellSize(fontSize: CGFloat) -> NSSize {
        let clampedFontSize = min(
            maximumTerminalFontSize,
            max(minimumTerminalFontSize, fontSize)
        )
        let font = monoFont(size: clampedFontSize)
        // Integral point cells keep 1x/2x backing geometry exact. Half-point
        // heights round asymmetrically (22px at 1x, 43px at 2x), which makes a
        // display move trigger needless atlas and PTY geometry churn.
        let wholePoint: (CGFloat) -> CGFloat = { $0.rounded(.up) }
        return NSSize(
            width: wholePoint(max(8, font.maximumAdvancement.width)),
            height: wholePoint(max(21, font.ascender - font.descender + font.leading + 3))
        )
    }
    static let terminalContentInset: CGFloat = 16

    static func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// A real shell theme may contain Powerline and Nerd Font glyphs before it
    /// prints its first prompt. Prefer an installed terminal face that carries
    /// those glyphs, then fall back to the dependable macOS faces. The app does
    /// not silently substitute a proportional UI font into the terminal grid.
    static let terminalFontCandidates = [
        BundledTerminalFont.postScriptName,
        "MesloLGS-NF-Regular",
        "JetBrainsMonoNFM-Regular",
        "JetBrainsMono-Regular",
        "Menlo-Regular",
        "Monaco",
    ]

    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // The Metal atlas needs a concrete PostScript face. SF Mono's hidden
        // PostScript names are not stable API, so it remains the semantic
        // fixed-pitch fallback instead of a name we pretend is portable.
        let concrete = terminalFontCandidates.lazy
            .compactMap { NSFont(name: $0, size: size) }
            .first(where: \.isFixedPitch)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return NSFontManager.shared.convert(
            concrete,
            toHaveTrait: weight >= .semibold ? .boldFontMask : []
        )
    }
}

final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateColor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    @objc private func displayOptionsChanged(_ notification: Notification) {
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = OuroTheme.border.cgColor
        }
    }
}

/// A quiet hierarchy surface. It deliberately avoids stacked blur/glass;
/// spacing, type, and one bounded edge carry the relationship instead.
final class SolidPanelView: NSView {
    private let panelCornerRadius: CGFloat

    init(cornerRadius: CGFloat = 8) {
        panelCornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        refreshStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }

    func refreshStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = panelCornerRadius
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderWidth = OuroTheme.accessibility.increaseContrast ? 1 : 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
