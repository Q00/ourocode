/// Memory policy for the one visible CAMetalLayer-backed terminal surface.
///
/// CAMetalLayer supports double or triple buffering; two is the minimum valid
/// drawable count. A 1136 x 976 BGRA terminal drawable is about 4.23 MiB of
/// pixel data, so raising this to three has a directly measurable cost. Keep
/// this policy UI-independent so its budget can be tested without allocating
/// a drawable or launching WindowServer.
enum TerminalMetalSurfaceMemoryPolicy {
    static let maximumDrawableCount = 2
    static let framebufferOnly = true
    static let presentsWithTransaction = false
    static let isPaused = true
    static let enableSetNeedsDisplay = true

    /// Raw pixel-storage ceiling for the configured drawable pool. IOSurface
    /// adds row/page alignment, so runtime residency will be slightly higher.
    static func drawablePoolPixelBytes(
        width: Int,
        height: Int,
        bytesPerPixel: Int = 4
    ) -> Int? {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return nil }
        let frameBytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        guard !frameBytes.overflow else { return nil }
        let poolBytes = frameBytes.partialValue.multipliedReportingOverflow(
            by: maximumDrawableCount
        )
        return poolBytes.overflow ? nil : poolBytes.partialValue
    }
}
