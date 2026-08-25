#if OUROCODE_GHOSTTY_METAL_SURFACE
  import Foundation
  import simd

  /// Pure color conversions shared by the retained scene and focused fixtures.
  /// Terminal colors cross the ABI as canonical sRGB bytes while the Metal
  /// drawable is sRGB, so shader inputs and clear colors must be linear.
  enum OuroTerminalColorSemantics {
    static let customUnderlineSurfaceFlag: UInt32 = 1 << 4
    static let foregroundUsesCanvasSurfaceFlag: UInt32 = 1 << 5
    static let backgroundUsesForegroundSurfaceFlag: UInt32 = 1 << 6

    static func linearRGBA(red: UInt8, green: UInt8, blue: UInt8) -> SIMD4<Float> {
      SIMD4(
        sRGBToLinear(Float(red) / 255),
        sRGBToLinear(Float(green) / 255),
        sRGBToLinear(Float(blue) / 255),
        1
      )
    }

    /// Mixes the command-turn tint in canonical sRGB bytes before converting
    /// to Metal's linear working space. This keeps the restrained visual tint from
    /// becoming a much brighter linear-light grey band on dark terminals.
    static func semanticTurnBackground(
      red: UInt8,
      green: UInt8,
      blue: UInt8,
      foregroundRed: UInt8,
      foregroundGreen: UInt8,
      foregroundBlue: UInt8,
      amount: Float = 0.11
    ) -> SIMD4<Float> {
      let clamped = min(1, max(0, amount))
      func mix(_ background: UInt8, _ foreground: UInt8) -> UInt8 {
        UInt8((Float(background) * (1 - clamped) + Float(foreground) * clamped).rounded())
      }
      return linearRGBA(
        red: mix(red, foregroundRed),
        green: mix(green, foregroundGreen),
        blue: mix(blue, foregroundBlue)
      )
    }

    /// Packs one canonical sRGB underline color into the instance's existing
    /// 32-bit reserved lane. Presence remains a surface flag, so black is not
    /// confused with the default-foreground underline semantic.
    static func packRGB(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
      UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    static func unpackRGB(_ packed: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8) {
      (
        UInt8(truncatingIfNeeded: packed >> 16),
        UInt8(truncatingIfNeeded: packed >> 8),
        UInt8(truncatingIfNeeded: packed)
      )
    }

    static func contrastRatio(_ first: SIMD4<Float>, _ second: SIMD4<Float>) -> Float {
      let firstLuminance = relativeLuminance(first)
      let secondLuminance = relativeLuminance(second)
      return (max(firstLuminance, secondLuminance) + 0.05)
        / (min(firstLuminance, secondLuminance) + 0.05)
    }

    /// CPU contract mirror for the shader's bounded selection override. It is
    /// kept pure so fixtures can lock the 4.5 boundary without a live drawable.
    static func selectionForeground(
      background: SIMD4<Float>,
      preferred: SIMD4<Float>
    ) -> SIMD4<Float> {
      guard contrastRatio(background, preferred) < 4.5 else { return preferred }
      let black = SIMD4<Float>(0, 0, 0, 1)
      let white = SIMD4<Float>(1, 1, 1, 1)
      return contrastRatio(background, black) >= contrastRatio(background, white)
        ? black : white
    }

    private static func relativeLuminance(_ color: SIMD4<Float>) -> Float {
      color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
    }

    private static func sRGBToLinear(_ component: Float) -> Float {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
  }

  /// The GPU instance deliberately remains four float4 values plus four UInt32
  /// lanes. Decoration color reuses the former reserved lane, so semantic color
  /// correctness does not increase per-cell memory or upload bandwidth.
  struct OuroTerminalCellInstance {
    var cellRect: SIMD4<Float>
    var glyphUV: SIMD4<Float>
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var terminalFlags: UInt32
    var underlineStyle: UInt32
    var surfaceFlags: UInt32
    var decorationColorBits: UInt32
  }
#endif
