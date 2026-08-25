import Foundation

enum OuroTerminalCommittedText {
    /// AppKit input methods may return canonically decomposed Hangul. Terminal
    /// grids advance per scalar unless the commit is normalized first, which
    /// renders one visible syllable as separate choseong/jungseong/jongseong
    /// cells. NFC is lossless and keeps non-Hangul text unchanged.
    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }
}
