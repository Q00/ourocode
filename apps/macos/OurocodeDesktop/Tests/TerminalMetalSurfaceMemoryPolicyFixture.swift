import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum TerminalMetalSurfaceMemoryPolicyFixture {
    static func main() {
        require(
            TerminalMetalSurfaceMemoryPolicy.maximumDrawableCount == 2,
            "the terminal surface must use CAMetalLayer's minimum double-buffer pool"
        )
        require(
            TerminalMetalSurfaceMemoryPolicy.framebufferOnly,
            "display drawables must not acquire shader-readable backing"
        )
        require(
            !TerminalMetalSurfaceMemoryPolicy.presentsWithTransaction,
            "terminal presentation must not retain drawables for Core Animation transactions"
        )
        require(
            TerminalMetalSurfaceMemoryPolicy.isPaused
                && TerminalMetalSurfaceMemoryPolicy.enableSetNeedsDisplay,
            "the terminal must remain damage-driven instead of continuously drawing"
        )
        require(
            TerminalMetalSurfaceMemoryPolicy.drawablePoolPixelBytes(width: 1136, height: 976)
                == 8_869_888,
            "the two-drawable BGRA pool budget changed"
        )
        require(
            TerminalMetalSurfaceMemoryPolicy.drawablePoolPixelBytes(
                width: Int.max,
                height: Int.max
            ) == nil,
            "drawable pool accounting must fail closed on overflow"
        )

        print("PASS: Metal terminal surface stays damage-driven with the minimum drawable pool")
    }
}
