#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import simd

  struct OuroTerminalAppearance: Equatable {
    let canvas: SIMD4<Float>
    let foreground: SIMD4<Float>
    let selection: SIMD4<Float>
    let cursor: SIMD4<Float>
    let reduceMotion: Bool
    let increaseContrast: Bool
    let reduceTransparency: Bool

    static func current(workspace: NSWorkspace = .shared) -> OuroTerminalAppearance {
      let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
      return OuroTerminalAppearance(
        canvas: OuroTerminalAppearance.linearRGBA(OuroTheme.canvas),
        foreground: OuroTerminalAppearance.linearRGBA(OuroTheme.text),
        selection: OuroTerminalAppearance.linearRGBA(NSColor.selectedContentBackgroundColor),
        cursor: OuroTerminalAppearance.linearRGBA(
          contrast ? NSColor.keyboardFocusIndicatorColor : OuroTheme.mint
        ),
        reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
        increaseContrast: contrast,
        reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
      )
    }

    static func linearRGBA(_ color: NSColor) -> SIMD4<Float> {
      // The drawable is bgra8Unorm_srgb, so fragment and clear values must be
      // linear. Passing gamma-encoded components caused dark #111214 to be
      // encoded a second time and appear around middle grey.
      let converted = color.usingColorSpace(.extendedSRGB) ?? color
      return SIMD4(
        sRGBToLinear(Float(converted.redComponent)),
        sRGBToLinear(Float(converted.greenComponent)),
        sRGBToLinear(Float(converted.blueComponent)),
        Float(converted.alphaComponent)
      )
    }

    private static func sRGBToLinear(_ component: Float) -> Float {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
  }

  final class OuroTerminalAppearanceMonitor: NSObject {
    var onChange: ((OuroTerminalAppearance) -> Void)?
    private(set) var value: OuroTerminalAppearance
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
      self.workspace = workspace
      value = .current(workspace: workspace)
      super.init()
      workspace.notificationCenter.addObserver(
        self,
        selector: #selector(displayOptionsChanged(_:)),
        name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        object: nil
      )
    }

    deinit {
      workspace.notificationCenter.removeObserver(self)
    }

    @objc private func displayOptionsChanged(_ notification: Notification) {
      refresh()
    }

    func refresh() {
      dispatchPrecondition(condition: .onQueue(.main))
      let next = OuroTerminalAppearance.current(workspace: workspace)
      guard next != value else { return }
      value = next
      onChange?(next)
    }
  }
#endif
