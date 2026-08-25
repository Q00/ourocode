import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalGlyphPlacementFixture {
    static func main() {
        let latin = TerminalGlyphPlacementPolicy.resolve(lineWidth: 8, tileWidth: 10, columns: 1)
        require(latin.horizontalScale == 1 && latin.originX == 1, "single-cell glyph was distorted")
        let hangul = TerminalGlyphPlacementPolicy.resolve(lineWidth: 16, tileWidth: 20, columns: 2)
        require(hangul.horizontalScale > 1, "narrow Hangul fallback did not fill its two-cell span")
        require(hangul.lineWidth(16) >= 18, "wide glyph retained excessive trailing whitespace")
        let alreadyWide = TerminalGlyphPlacementPolicy.resolve(lineWidth: 19, tileWidth: 20, columns: 2)
        require(alreadyWide.horizontalScale == 1, "well-fitted CJK glyph was needlessly stretched")
        print("PASS: wide fallback glyphs fill their terminal span without changing cell authority")
    }
}

private extension TerminalGlyphPlacement {
    func lineWidth(_ width: CGFloat) -> CGFloat { width * horizontalScale }
}
