import AppKit
import QuartzCore

struct TerminalTabOverflowVisibility: Equatable {
  let leading: Bool
  let trailing: Bool

  static func resolve(
    viewportOrigin: CGFloat,
    viewportWidth: CGFloat,
    contentWidth: CGFloat
  ) -> Self {
    guard viewportOrigin.isFinite, viewportWidth.isFinite, contentWidth.isFinite,
      viewportWidth > 0, contentWidth > viewportWidth + 1
    else { return Self(leading: false, trailing: false) }
    let maximumOrigin = max(0, contentWidth - viewportWidth)
    let origin = min(max(0, viewportOrigin), maximumOrigin)
    return Self(
      leading: origin > 0.5,
      trailing: origin < maximumOrigin - 0.5
    )
  }
}

struct TerminalTabWidthPolicy {
  static let minimumWidth: CGFloat = 84
  static let maximumWidth: CGFloat = 180

  static func width(
    preferredWidth: CGFloat,
    availableWidth: CGFloat,
    visibleCount: Int
  ) -> CGFloat {
    guard preferredWidth.isFinite, availableWidth.isFinite,
      preferredWidth > 0, availableWidth > 0, visibleCount > 0
    else { return minimumWidth }
    let preferred = min(maximumWidth, max(minimumWidth, preferredWidth))
    let availablePerTab = availableWidth / CGFloat(visibleCount)
    return min(preferred, max(minimumWidth, availablePerTab))
  }
}

/// A quiet, non-interactive indication that more tabs exist beyond the clip.
/// The cue never enters the hit-test or accessibility trees.
final class TerminalTabOverflowCueView: NSView {
  enum Edge { case leading, trailing }

  private let edge: Edge
  private let gradient = CAGradientLayer()

  init(edge: Edge) {
    self.edge = edge
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.addSublayer(gradient)
    setAccessibilityElement(false)
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(displayOptionsChanged(_:)),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    refreshStyle()
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    gradient.frame = bounds
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshStyle()
  }

  @objc private func displayOptionsChanged(_ notification: Notification) {
    refreshStyle()
  }

  private func refreshStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let base = NSColor.windowBackgroundColor
      let accessibility = OuroTheme.accessibility
      if accessibility.reduceTransparency || accessibility.increaseContrast {
        gradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = accessibility.increaseContrast ? 1 : 0.5
      } else {
        let clear = base.withAlphaComponent(0)
        gradient.colors = edge == .leading
          ? [base.cgColor, clear.cgColor]
          : [clear.cgColor, base.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
      }
    }
  }
}
