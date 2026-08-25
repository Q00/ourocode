import Darwin
import Foundation
import simd

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum OuroTerminalColorSemanticsFixture {
  static func main() {
    require(
      MemoryLayout<OuroTerminalCellInstance>.stride == 80,
      "terminal cell instance stride changed from 80 bytes"
    )
    require(
      MemoryLayout<OuroTerminalCellInstance>.size == 80,
      "terminal cell instance gained hidden payload"
    )

    let packed = OuroTerminalColorSemantics.packRGB(red: 4, green: 5, blue: 6)
    require(packed == 0x04_05_06, "SGR 58 canonical RGB packing changed")
    let unpacked = OuroTerminalColorSemantics.unpackRGB(packed)
    require(
      unpacked.red == 4 && unpacked.green == 5 && unpacked.blue == 6,
      "SGR 58 canonical RGB did not round-trip"
    )
    require(
      OuroTerminalColorSemantics.packRGB(red: 0, green: 0, blue: 0) == 0
        && OuroTerminalColorSemantics.customUnderlineSurfaceFlag != 0,
      "custom black underline is not distinguishable from default underline"
    )
    require(
      OuroTerminalColorSemantics.foregroundUsesCanvasSurfaceFlag
        != OuroTerminalColorSemantics.backgroundUsesForegroundSurfaceFlag,
      "inverse OSC 10/11 provenance flags overlap"
    )
    let turn = OuroTerminalColorSemantics.semanticTurnBackground(
      red: 0x11,
      green: 0x12,
      blue: 0x14,
      foregroundRed: 0xE6,
      foregroundGreen: 0xE6,
      foregroundBlue: 0xE6
    )
    let plain = OuroTerminalColorSemantics.linearRGBA(red: 0x11, green: 0x12, blue: 0x14)
    require(turn.x > plain.x && turn.y > plain.y && turn.z > plain.z,
            "semantic turn tint did not move toward the foreground")
    let clamped = OuroTerminalColorSemantics.semanticTurnBackground(
      red: 0x11, green: 0x12, blue: 0x14,
      foregroundRed: 0xE6, foregroundGreen: 0xE6, foregroundBlue: 0xE6,
      amount: 9
    )
    let foreground = OuroTerminalColorSemantics.linearRGBA(red: 0xE6, green: 0xE6, blue: 0xE6)
    require(clamped == foreground, "semantic turn amount was not bounded")

    let black = SIMD4<Float>(0, 0, 0, 1)
    let white = SIMD4<Float>(1, 1, 1, 1)
    // Bracket the 4.5 threshold instead of relying on an exactly representable
    // decimal in Float (0.175 is not exact in binary floating point).
    let acceptedBoundary = SIMD4<Float>(repeating: 0.1751).replacingW(with: 1)
    require(
      OuroTerminalColorSemantics.selectionForeground(
        background: acceptedBoundary,
        preferred: black
      ) == black,
      "preferred selection foreground was replaced above the 4.5 boundary"
    )
    let belowBoundary = SIMD4<Float>(repeating: 0.1749).replacingW(with: 1)
    require(
      OuroTerminalColorSemantics.selectionForeground(
        background: belowBoundary,
        preferred: black
      ) == white,
      "selection fallback did not choose the higher-contrast bounded color below 4.5"
    )

    print("PASS: 80-byte stride, SGR 58 packing, inverse provenance, and selection contrast")
  }
}

private extension SIMD4 where Scalar == Float {
  func replacingW(with value: Float) -> SIMD4<Float> {
    SIMD4(x, y, z, value)
  }
}
